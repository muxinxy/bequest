package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

// TestInheritancePreview: 3 资产(1 绑 asset、1 在绑了 category 的分组、1 未绑定)
// -> 断言 assets 映射 via、inheritors asset_count、trigger_days。
func TestInheritancePreview(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")

	// 建分组并绑定继承人。
	cat := doReq(t, ts, http.MethodPost, "/api/v1/categories", `{"name":"保险"}`, token)
	if cat.Code != http.StatusCreated {
		t.Fatalf("create category: %d body=%s", cat.Code, cat.Body.String())
	}
	var catID int64
	if err := db.QueryRow(`SELECT id FROM categories WHERE user_id=? AND name='保险'`, uid).Scan(&catID); err != nil {
		t.Fatalf("get category id: %v", err)
	}

	// 3 个继承人。
	zhang := createInheritor(t, ts, token, "张三", "zhang@example.com", "abc12345")
	li := createInheritor(t, ts, token, "李四", "li@example.com", "abc12345")
	wang := createInheritor(t, ts, token, "王五", "wang@example.com", "abc12345")

	// 资产 1:绑 asset_inheritors(张三)。
	rr := createAsset(t, ts, token, "我的保险")
	if rr.Code != http.StatusCreated {
		t.Fatalf("create asset1: %d body=%s", rr.Code, rr.Body.String())
	}
	var asset1 int64
	if err := db.QueryRow(`SELECT id FROM assets WHERE user_id=? AND name='我的保险'`, uid).Scan(&asset1); err != nil {
		t.Fatalf("get asset1: %v", err)
	}
	if rr := doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/assets/%d/inheritors", asset1),
		fmt.Sprintf(`{"inheritor_id":%d,"ladder_id":null}`, zhang), token); rr.Code != http.StatusCreated {
		t.Fatalf("bind asset1: %d body=%s", rr.Code, rr.Body.String())
	}

	// 资产 2:在绑了 category_inheritors 的分组(李四)。
	rr = createAsset(t, ts, token, "域名")
	if rr.Code != http.StatusCreated {
		t.Fatalf("create asset2: %d body=%s", rr.Code, rr.Body.String())
	}
	var asset2 int64
	if err := db.QueryRow(`SELECT id FROM assets WHERE user_id=? AND name='域名'`, uid).Scan(&asset2); err != nil {
		t.Fatalf("get asset2: %v", err)
	}
	if _, err := db.Exec(`UPDATE assets SET category_id = ? WHERE id = ?`, catID, asset2); err != nil {
		t.Fatalf("set asset2 category: %v", err)
	}
	if rr := doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/categories/%d/inheritors", catID),
		fmt.Sprintf(`{"inheritor_id":%d,"ladder_id":null}`, li), token); rr.Code != http.StatusCreated {
		t.Fatalf("bind category: %d body=%s", rr.Code, rr.Body.String())
	}

	// 资产 3:未绑定(用户级全量,王五为 priority 最小继承人)。
	rr = createAsset(t, ts, token, "钱包")
	if rr.Code != http.StatusCreated {
		t.Fatalf("create asset3: %d body=%s", rr.Code, rr.Body.String())
	}

	// 王五 priority 最小 -> 用户级全量继承人。
	if _, err := db.Exec(`UPDATE inheritors SET priority = 0 WHERE id = ?`, wang); err != nil {
		t.Fatalf("set wang priority: %v", err)
	}

	rr = doReq(t, ts, http.MethodGet, "/api/v1/inheritance/preview", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("preview: %d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		Ladder              previewLadder     `json:"ladder"`
		TriggerDays         int               `json:"trigger_days"`
		TotalAssets         int               `json:"total_assets"`
		InheritedAssets     int               `json:"inherited_assets"`
		Assets              []previewAsset    `json:"assets"`
		Inheritors          []previewInheritor `json:"inheritors"`
		UserLevelInheritors []string          `json:"user_level_inheritors"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse preview: %v body=%s", err, rr.Body.String())
	}

	if resp.TriggerDays != 60 {
		t.Fatalf("trigger_days=%d want 60", resp.TriggerDays)
	}
	if resp.TotalAssets != 3 || resp.InheritedAssets != 3 {
		t.Fatalf("total=%d inherited=%d want 3/3", resp.TotalAssets, resp.InheritedAssets)
	}
	if len(resp.Assets) != 3 {
		t.Fatalf("assets len=%d want 3", len(resp.Assets))
	}
	// 资产 1 -> via asset,张三
	if resp.Assets[0].Via != "asset" || resp.Assets[0].InheritorName != "张三" {
		t.Fatalf("asset1 via=%s name=%s want asset/张三", resp.Assets[0].Via, resp.Assets[0].InheritorName)
	}
	// 资产 2 -> via category,李四
	if resp.Assets[1].Via != "category" || resp.Assets[1].InheritorName != "李四" {
		t.Fatalf("asset2 via=%s name=%s want category/李四", resp.Assets[1].Via, resp.Assets[1].InheritorName)
	}
	// 资产 3 -> via user,无继承人
	if resp.Assets[2].Via != "user" || resp.Assets[2].InheritorID != nil {
		t.Fatalf("asset3 via=%s want user with nil inheritor", resp.Assets[2].Via)
	}

	// 继承人 asset_count:张三 1、李四 1、王五 1(用户级全量)。
	counts := map[string]int{}
	for _, in := range resp.Inheritors {
		counts[in.Name] = in.AssetCount
	}
	if counts["张三"] != 1 || counts["李四"] != 1 || counts["王五"] != 1 {
		t.Fatalf("asset_count=%v want 张三:1 李四:1 王五:1", counts)
	}
	if len(resp.UserLevelInheritors) != 1 || resp.UserLevelInheritors[0] != "王五" {
		t.Fatalf("user_level_inheritors=%v want [王五]", resp.UserLevelInheritors)
	}
	if !strings.Contains(resp.Ladder.Name, "全局") || len(resp.Ladder.Days) != 2 {
		t.Fatalf("ladder=%+v want global 2 days", resp.Ladder)
	}
}

// TestNotificationUsage: 免费用户 email_limit=freeMonthlyEmails、sms_limit=0;
// quotaIncr 2 次后 email_used=2;改 member 后 sms_limit=memberMonthlySms。
func TestNotificationUsage(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")

	rr := doReq(t, ts, http.MethodGet, "/api/v1/notification-usage", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("usage: %d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		Month      string `json:"month"`
		EmailUsed  int    `json:"email_used"`
		EmailLimit int    `json:"email_limit"`
		SmsUsed    int    `json:"sms_used"`
		SmsLimit   int    `json:"sms_limit"`
		Tier       string `json:"tier"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse usage: %v", err)
	}
	if resp.Tier != "free" || resp.EmailLimit != freeMonthlyEmails || resp.SmsLimit != 0 {
		t.Fatalf("free usage=%+v want tier=free limit=%d sms=0", resp, freeMonthlyEmails)
	}

	quotaIncr(db, uid, "email")
	quotaIncr(db, uid, "email")
	rr = doReq(t, ts, http.MethodGet, "/api/v1/notification-usage", "", token)
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse usage 2: %v", err)
	}
	if resp.EmailUsed != 2 {
		t.Fatalf("email_used=%d want 2", resp.EmailUsed)
	}

	if _, err := db.Exec(`UPDATE users SET tier = 'member' WHERE id = ?`, uid); err != nil {
		t.Fatalf("set member: %v", err)
	}
	rr = doReq(t, ts, http.MethodGet, "/api/v1/notification-usage", "", token)
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse usage 3: %v", err)
	}
	if resp.Tier != "member" || resp.EmailLimit != memberMonthlyEmails || resp.SmsLimit != memberMonthlySms {
		t.Fatalf("member usage=%+v want limit=%d sms=%d", resp, memberMonthlyEmails, memberMonthlySms)
	}
}
