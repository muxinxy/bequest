package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// langResp is the JSON shape returned by GET/PUT /api/v1/settings/lang.
type langResp struct {
	Lang string `json:"lang"`
}

func getLang(t *testing.T, ts *httptest.Server, token string) langResp {
	t.Helper()
	rr := doReq(t, ts, http.MethodGet, "/api/v1/settings/lang", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("GET /settings/lang status = %d, body=%s", rr.Code, rr.Body.String())
	}
	var res langResp
	if err := json.Unmarshal(rr.Body.Bytes(), &res); err != nil {
		t.Fatalf("parse lang response: %v (body=%s)", err, rr.Body.String())
	}
	return res
}

// TestSettingsLangRoundTrip: default zh -> PUT en reflects on GET.
// 跨三种方言(newTestServer 按 TEST_DB_DRIVER 走 sqlite/mysql/postgres)。
func TestSettingsLangRoundTrip(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := userIDOf(t, ts, token)

	// 新用户默认 zh(列默认值,注册 SQL 未显式写 lang)。
	if got := getLang(t, ts, token); got.Lang != "zh" {
		t.Fatalf("default lang = %q, want zh", got.Lang)
	}

	// PUT en -> 200 {"lang":"en"},GET 反映 en。
	put := doReq(t, ts, http.MethodPut, "/api/v1/settings/lang", `{"lang":"en"}`, token)
	if put.Code != http.StatusOK {
		t.Fatalf("PUT lang=en status = %d, body=%s", put.Code, put.Body.String())
	}
	if !strings.Contains(put.Body.String(), `"lang":"en"`) {
		t.Fatalf("PUT response = %s, want lang en", put.Body.String())
	}
	if got := getLang(t, ts, token); got.Lang != "en" {
		t.Fatalf("lang after PUT = %q, want en", got.Lang)
	}
	// 落库确认(方言无关的 ? 占位符查询)。
	var stored string
	if err := db.QueryRow(`SELECT lang FROM users WHERE id = ?`, uid).Scan(&stored); err != nil {
		t.Fatalf("query stored lang: %v", err)
	}
	if stored != "en" {
		t.Fatalf("stored lang = %q, want en", stored)
	}

	// 切回 zh。
	putBack := doReq(t, ts, http.MethodPut, "/api/v1/settings/lang", `{"lang":"zh"}`, token)
	if putBack.Code != http.StatusOK {
		t.Fatalf("PUT lang=zh status = %d, body=%s", putBack.Code, putBack.Body.String())
	}
	if got := getLang(t, ts, token); got.Lang != "zh" {
		t.Fatalf("lang after PUT zh = %q, want zh", got.Lang)
	}
}

// TestSettingsLangInvalid: 仅接受 zh/en,其余 400。
func TestSettingsLangInvalid(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "bob")

	for _, bad := range []string{`{"lang":"xx"}`, `{"lang":"fr"}`, `{"lang":"EN"}`, `{"lang":""}`} {
		rr := doReq(t, ts, http.MethodPut, "/api/v1/settings/lang", bad, token)
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("PUT lang=%s status = %d, want 400, body=%s", bad, rr.Code, rr.Body.String())
		}
	}
	// 非法 PUT 不改变偏好。
	if got := getLang(t, ts, token); got.Lang != "zh" {
		t.Fatalf("lang after rejected PUTs = %q, want zh", got.Lang)
	}
}

// TestUserMsgLocalization: userMsg 对 en 输出英文、zh 保持中文、未知键安全降级。
func TestUserMsgLocalization(t *testing.T) {
	if got := userMsg("en", "长时间未登录提醒"); got != "Long inactivity reminder" {
		t.Fatalf("userMsg en title = %q", got)
	}
	if got := userMsg("zh", "长时间未登录提醒"); got != "长时间未登录提醒" {
		t.Fatalf("userMsg zh must keep Chinese, got %q", got)
	}
	if got := userMsg("en", "资产「%s」即将到期"); got != "Asset \"%s\" is expiring soon" {
		t.Fatalf("userMsg en fmt title = %q", got)
	}
	// 未收录的键在 en 下原样返回(安全降级)。
	if got := userMsg("en", "未翻译的文案"); got != "未翻译的文案" {
		t.Fatalf("userMsg en unknown key = %q, want passthrough", got)
	}
}

// TestSettingsLangLocalizesSchedulerCopy: en 用户在预设模板缺失(回退硬编码)
// 时,调度器/提醒生成的标题与正文为英文;zh 用户保持中文。
// 走真实 scan/notifyEscalation 路径,方言无关(? 占位符由驱动改写)。
func TestSettingsLangLocalizesSchedulerCopy(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")

	// 清空该库系统预设模板,强制走回退硬编码路径(仅本测试库受影响)。
	if _, err := db.Exec(`DELETE FROM reminder_templates`); err != nil {
		t.Fatalf("delete preset templates: %v", err)
	}

	// 语言偏好无效前,zh 用户触发到期提醒 -> 中文回退。
	mkAsset := func(name, expiry string) {
		t.Helper()
		payload := base64.StdEncoding.EncodeToString([]byte("secret"))
		body := fmt.Sprintf(`{"name":%q,"asset_type":"virtual","encrypted_data":%q,"expiry_date":%q}`, name, payload, expiry)
		if rr := doReq(t, ts, http.MethodPost, "/api/v1/assets", body, token); rr.Code != http.StatusCreated {
			t.Fatalf("create asset %s: %d body=%s", name, rr.Code, rr.Body.String())
		}
	}
	now := time.Now().UTC()
	mkAsset("旧卡", now.AddDate(0, 0, -2).Format("2006-01-02"))
	scan(db, now)
	var zhTitle, zhBody string
	if err := db.QueryRow(`SELECT title, body FROM reminders WHERE user_id = ? AND type = 'expiry' AND dedup_key LIKE '%:past'`, uid).
		Scan(&zhTitle, &zhBody); err != nil {
		t.Fatalf("query zh expiry reminder: %v", err)
	}
	if zhTitle != "资产「旧卡」已到期" {
		t.Fatalf("zh title = %q, want Chinese fallback", zhTitle)
	}

	// 切到 en 并换一个到期资产 + 时间窗后重扫,验证英文回退。
	if rr := doReq(t, ts, http.MethodPut, "/api/v1/settings/lang", `{"lang":"en"}`, token); rr.Code != http.StatusOK {
		t.Fatalf("PUT lang=en: %d body=%s", rr.Code, rr.Body.String())
	}
	mkAsset("旧卡en", now.AddDate(0, 0, -3).Format("2006-01-02"))
	scan(db, now.AddDate(0, 0, 1))
	var enTitle, enBody string
	if err := db.QueryRow(`SELECT title, body FROM reminders WHERE user_id = ? AND type = 'expiry' AND dedup_key LIKE '%:past' ORDER BY id DESC LIMIT 1`, uid).
		Scan(&enTitle, &enBody); err != nil {
		t.Fatalf("query en expiry reminder: %v", err)
	}
	if enTitle != `Asset "旧卡en" has expired` {
		t.Fatalf("en title = %q, want English fallback", enTitle)
	}
	if !strings.Contains(enBody, "expired on") {
		t.Fatalf("en body = %q, want English body", enBody)
	}

	// 升级通知回退:notifyEscalation 走一级(40 天,阶梯 [15,60])。
	notifyEscalation(db, uid, "free", 40, []int{15, 60})
	var escTitle, escBody string
	if err := db.QueryRow(`SELECT title, body FROM reminders WHERE user_id = ? AND type = 'escalation' ORDER BY id DESC LIMIT 1`, uid).
		Scan(&escTitle, &escBody); err != nil {
		t.Fatalf("query escalation reminder: %v", err)
	}
	if escTitle != "Long inactivity reminder" {
		t.Fatalf("en escalation title = %q, want English", escTitle)
	}
	if !strings.Contains(escBody, "You have not logged in for 40 days") {
		t.Fatalf("en escalation body = %q, want English", escBody)
	}
}
