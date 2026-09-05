package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// ---------- 2FA (TOTP) 登录流程 ----------

func Test2FALoginFlow(t *testing.T) {
	ts, db := newTestServer(t)
	admTok, _ := loginAdmin(t, ts, db, "root", "adminpass123")

	// 启用前 /admin/2fa 状态
	rr := doReq(t, ts, http.MethodGet, "/api/v1/admin/2fa", "", admTok)
	if rr.Code != http.StatusOK || !jsonContains(rr.Body.String(), `"enabled":false`) {
		t.Fatalf("2fa status before: %s", rr.Body.String())
	}

	// setup 返回密钥(未落库)
	rr = doReq(t, ts, http.MethodPost, "/api/v1/admin/2fa/setup", "", admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("2fa setup: status=%d", rr.Code)
	}
	var setup struct {
		Secret string `json:"secret"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &setup); err != nil || setup.Secret == "" {
		t.Fatalf("2fa setup parse: %v %s", err, rr.Body.String())
	}

	// 错误动态码 → 拒绝
	rr = doReq(t, ts, http.MethodPost, "/api/v1/admin/2fa/confirm",
		fmt.Sprintf(`{"secret":%q,"code":"000000"}`, setup.Secret), admTok)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("2fa confirm wrong code: want 400, got %d", rr.Code)
	}

	// 正确动态码 → 启用
	code, err := totpCode(setup.Secret, time.Now())
	if err != nil {
		t.Fatalf("totp: %v", err)
	}
	rr = doReq(t, ts, http.MethodPost, "/api/v1/admin/2fa/confirm",
		fmt.Sprintf(`{"secret":%q,"code":%q}`, setup.Secret, code), admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("2fa confirm: status=%d body=%s", rr.Code, rr.Body.String())
	}

	// 登录 → totp_required + pending_token(不返回正式 token)
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/login", `{"username":"root","password":"adminpass123"}`, "")
	var step1 struct {
		Token        string `json:"token"`
		TotpRequired bool   `json:"totp_required"`
		PendingToken string `json:"pending_token"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &step1); err != nil {
		t.Fatalf("parse step1: %v", err)
	}
	if !step1.TotpRequired || step1.PendingToken == "" || step1.Token != "" {
		t.Fatalf("step1 want totp_required+pending, got %s", rr.Body.String())
	}

	// pending token 不能当会话用
	rr = doReq(t, ts, http.MethodGet, "/api/v1/me", "", step1.PendingToken)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("pending token on /me: want 401, got %d", rr.Code)
	}

	// 错误动态码 → 401
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/2fa/verify",
		fmt.Sprintf(`{"pending_token":%q,"code":"000000"}`, step1.PendingToken), "")
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("2fa verify wrong code: want 401, got %d", rr.Code)
	}

	// 正确动态码 → 正式 token
	code2, _ := totpCode(setup.Secret, time.Now())
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/2fa/verify",
		fmt.Sprintf(`{"pending_token":%q,"code":%q}`, step1.PendingToken, code2), "")
	var step2 struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &step2); err != nil || step2.Token == "" {
		t.Fatalf("2fa verify ok: %s", rr.Body.String())
	}
	if rr := doReq(t, ts, http.MethodGet, "/api/v1/me", "", step2.Token); rr.Code != http.StatusOK {
		t.Fatalf("post-2fa token on /me: want 200, got %d", rr.Code)
	}

	// 停用(需要当前动态码)
	code3, _ := totpCode(setup.Secret, time.Now())
	rr = doReq(t, ts, http.MethodPost, "/api/v1/admin/2fa/disable",
		fmt.Sprintf(`{"code":%q}`, code3), step2.Token)
	if rr.Code != http.StatusOK {
		t.Fatalf("2fa disable: status=%d body=%s", rr.Code, rr.Body.String())
	}

	// 停用后登录不再要求 2FA
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/login", `{"username":"root","password":"adminpass123"}`, "")
	var step3 struct {
		TotpRequired bool   `json:"totp_required"`
		Token        string `json:"token"`
	}
	json.Unmarshal(rr.Body.Bytes(), &step3)
	if step3.TotpRequired || step3.Token == "" {
		t.Fatalf("after disable login: %s", rr.Body.String())
	}
}

// ---------- claim 失败审计 ----------

func TestClaimFailedAudit(t *testing.T) {
	ts, db := newTestServer(t)
	// 未知 event_key → 401 + 审计
	rr := doReq(t, ts, http.MethodPost, "/api/v1/inheritance/claim", `{"event_key":"nope","access_code":"x"}`, "")
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("claim unknown: want 401, got %d", rr.Code)
	}
	if n := countRows(t, db, `SELECT COUNT(*) FROM audit_logs WHERE action='claim_failed'`); n == 0 {
		t.Fatal("claim_failed audit missing")
	}
	// 已知 event_key + 错误访问码 → 401 + 审计(actor=inheritor)
	token := registerUser(t, ts, "alice")
	inID := createInheritor(t, ts, token, "bob", "bob@example.com", "abc12345")
	if _, err := db.Exec(`INSERT INTO inheritance_events (user_id, inheritor_id, event_key, access_code_hash, status) VALUES (?, ?, ?, ?, 'pending')`,
		userIDOf(t, ts, token), inID, "evt-key-2", hashAccessCode("abc12345")); err != nil {
		t.Fatalf("insert event: %v", err)
	}
	rr = doReq(t, ts, http.MethodPost, "/api/v1/inheritance/claim", `{"event_key":"evt-key-2","access_code":"wrong"}`, "")
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("claim wrong code: want 401, got %d", rr.Code)
	}
	if n := countRows(t, db, `SELECT COUNT(*) FROM audit_logs WHERE action='claim_failed' AND actor='inheritor'`); n == 0 {
		t.Fatal("inheritor claim_failed audit missing")
	}
}

func userIDOf(t *testing.T, ts *httptest.Server, token string) int64 {
	t.Helper()
	var resp struct {
		User struct {
			ID int64 `json:"id"`
		} `json:"user"`
	}
	if err := json.Unmarshal(doReq(t, ts, http.MethodGet, "/api/v1/me", "", token).Body.Bytes(), &resp); err != nil {
		t.Fatalf("me: %v", err)
	}
	return resp.User.ID
}

// ---------- 72h 反悔窗口 ----------

func Test72hReversalWindow(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := userIDOf(t, ts, token)
	inID := createInheritor(t, ts, token, "bob", "bob@example.com", "abc12345")

	insertEvent := func(key string) {
		t.Helper()
		if _, err := db.Exec(`INSERT INTO inheritance_events (user_id, inheritor_id, event_key, access_code_hash, status) VALUES (?, ?, ?, ?, 'pending')`,
			uid, inID, key, hashAccessCode("abc12345")); err != nil {
			t.Fatalf("insert event: %v", err)
		}
	}
	claim := func(key string) {
		t.Helper()
		rr := doReq(t, ts, http.MethodPost, "/api/v1/inheritance/claim",
			fmt.Sprintf(`{"event_key":%q,"access_code":"abc12345"}`, key), "")
		if rr.Code != http.StatusOK {
			t.Fatalf("claim %s: status=%d body=%s", key, rr.Code, rr.Body.String())
		}
		var c struct {
			Status          string `json:"status"`
			ReversableUntil string `json:"reversable_until"`
		}
		json.Unmarshal(rr.Body.Bytes(), &c)
		if c.Status != "claimed" || c.ReversableUntil == "" {
			t.Fatalf("claim %s response: %s", key, rr.Body.String())
		}
	}

	// 事件 A:窗口内号主登录 → 反转(反悔权有效)。
	insertEvent("evt-a")
	claim("evt-a")
	doReq(t, ts, http.MethodPost, "/api/v1/auth/login", `{"username":"alice","password":"password123"}`, "")
	if n := countRows(t, db, `SELECT COUNT(*) FROM inheritance_events WHERE event_key='evt-a' AND status='reversed'`); n != 1 {
		t.Fatalf("within window: want reversed, got %d", n)
	}

	// 事件 B:超过 72h 后登录 → 保持 claimed(交接最终完成,不可反转)。
	insertEvent("evt-b")
	claim("evt-b")
	if _, err := db.Exec(`UPDATE inheritance_events SET reversable_until = ` + dbNowAdd("-1 hour") + ` WHERE event_key = 'evt-b'`); err != nil {
		t.Fatalf("force expiry: %v", err)
	}
	doReq(t, ts, http.MethodPost, "/api/v1/auth/login", `{"username":"alice","password":"password123"}`, "")
	if n := countRows(t, db, `SELECT COUNT(*) FROM inheritance_events WHERE event_key='evt-b' AND status='claimed'`); n != 1 {
		t.Fatalf("after window: want claimed, got %d", n)
	}
}

// ---------- 用户资产明细 + provider 配置 ----------

func TestAdminUserAssetsAndProviders(t *testing.T) {
	ts, db := newTestServer(t)
	userTok := registerUser(t, ts, "alice")
	admTok, _ := loginAdmin(t, ts, db, "root", "adminpass123")
	aliceID := userIDOf(t, ts, userTok)

	// 建一个资产
	rr := doReq(t, ts, http.MethodPost, "/api/v1/assets",
		`{"name":"银行卡","asset_type":"virtual","encrypted_data":"QUJD"}`+"", userTok)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create asset: status=%d", rr.Code)
	}

	// 管理端资产明细:仅元数据,不含密文
	rr = doReq(t, ts, http.MethodGet, fmt.Sprintf("/api/v1/admin/users/%d/assets", aliceID), "", admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("admin assets: status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !jsonContains(rr.Body.String(), "银行卡") || jsonContains(rr.Body.String(), "encrypted_data") {
		t.Fatalf("admin assets shape: %s", rr.Body.String())
	}

	// 配置:provider 往返(留空保留密钥)
	old := configFile
	configFile = t.TempDir() + "/config.json"
	t.Cleanup(func() { configFile = old; smsProviders = nil; phoneProviders = nil })
	rr = doReq(t, ts, http.MethodPut, "/api/v1/admin/config",
		`{"smtp_servers":[],"sms_providers":[{"name":"aliyun","api_key":"k1","api_secret":"s1"}],"phone_providers":[{"name":"twilio","api_key":"tk","api_secret":"ts"}],"free_asset_quota":50}`,
		admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("put config: status=%d body=%s", rr.Code, rr.Body.String())
	}
	rr = doReq(t, ts, http.MethodGet, "/api/v1/admin/config", "", admTok)
	if !jsonContains(rr.Body.String(), `"name":"aliyun"`) || jsonContains(rr.Body.String(), `"k1"`) {
		t.Fatalf("config get: %s", rr.Body.String())
	}
	// 空密钥保留原值:回读文件确认 s1 还在
	rr = doReq(t, ts, http.MethodPut, "/api/v1/admin/config",
		`{"smtp_servers":[],"sms_providers":[{"name":"aliyun","api_key":"","api_secret":""}],"phone_providers":[],"free_asset_quota":50}`,
		admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("put config 2: status=%d", rr.Code)
	}
	cfg := readConfigFile()
	if len(cfg.SMSProviders) != 1 || cfg.SMSProviders[0].APIKey != "k1" || cfg.SMSProviders[0].APISecret != "s1" {
		t.Fatalf("provider secret not preserved: %+v", cfg.SMSProviders)
	}
}
