package main

import (
	"encoding/json"
	"testing"
)

// TestMaskProviders:maskProviders 只暴露名称与 *_set 标记,不泄露明文密钥。
func TestMaskProviders(t *testing.T) {
	ps := []provider{
		{Name: "aliyun", APIKey: "ak-secret", APISecret: "sk-secret"},
		{Name: "twilio", APIKey: "", APISecret: ""},
	}
	masked := maskProviders(ps)
	if len(masked) != 2 {
		t.Fatalf("masked len = %d, want 2", len(masked))
	}
	if masked[0]["name"] != "aliyun" || masked[0]["api_key_set"] != true || masked[0]["api_secret_set"] != true {
		t.Fatalf("unexpected masked[0]: %+v", masked[0])
	}
	if masked[1]["api_key_set"] != false || masked[1]["api_secret_set"] != false {
		t.Fatalf("unexpected masked[1]: %+v", masked[1])
	}
	// 序列化后不得泄露明文密钥
	b, _ := json.Marshal(masked)
	s := string(b)
	if jsonContains(s, "ak-secret") {
		t.Fatal("maskProviders leaked api_key plaintext")
	}
	if jsonContains(s, "sk-secret") {
		t.Fatal("maskProviders leaked api_secret plaintext")
	}
}

// TestSmsProviderRouting:只测 provider 加载逻辑(不真正发短信)。
// 无 provider 时 sendSMS 打日志跳过不 panic;插入 2 个 enabled provider 后
// enabledSMSProviders 能正确加载。
func TestSmsProviderRouting(t *testing.T) {
	ts, db := newTestServer(t)
	_ = ts

	// 无 provider 配置:sendSMS 应正常返回,不 panic
	sendSMS(db, "13800000000", "test")

	// 插入 2 个 enabled provider,验证加载逻辑
	for _, p := range []struct {
		provider, name, ak, sk, extra string
	}{
		{"tencent", "腾讯主号", "ak1", "sk1", `{"sdk_app_id":"x","sign_name":"y","template_id":"z"}`},
		{"aliyun", "阿里主号", "ak2", "sk2", `{"sign_name":"y","template_code":"z"}`},
	} {
		if _, err := db.Exec(`INSERT INTO sms_providers (provider, name, access_key, secret_key, extra, enabled)
			VALUES (?, ?, ?, ?, ?, 1)`, p.provider, p.name, p.ak, p.sk, p.extra); err != nil {
			t.Fatalf("insert provider %s: %v", p.name, err)
		}
	}
	provs := enabledSMSProviders(db)
	if len(provs) != 2 {
		t.Fatalf("enabled providers = %d, want 2", len(provs))
	}
	if provs[0].provider != "tencent" || provs[0].accessKey != "ak1" || provs[0].secretKey != "sk1" {
		t.Fatalf("unexpected provs[0]: %+v", provs[0])
	}
	if provs[1].provider != "aliyun" || provs[1].accessKey != "ak2" {
		t.Fatalf("unexpected provs[1]: %+v", provs[1])
	}
}