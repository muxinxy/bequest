package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"
)

// genAdminCodes 以 admin 身份生成 count 个 duration_days 天的兑换码,返回 codes 数组。
func genAdminCodes(t *testing.T, ts *httptest.Server, db *sql.DB, count, durationDays int) []string {
	t.Helper()
	admTok, _ := loginAdmin(t, ts, db, "root", "adminpass123")
	rr := doReq(t, ts, http.MethodPost, "/api/v1/admin/redemption-codes",
		fmt.Sprintf(`{"count":%d,"duration_days":%d}`, count, durationDays), admTok)
	if rr.Code != http.StatusCreated {
		t.Fatalf("gen codes: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		Codes []string `json:"codes"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse gen codes: %v", err)
	}
	return resp.Codes
}

// codeRe 匹配 XXXX-XXXX-XXXX 格式(字符集去掉易混淆的 0O1IL)。
var codeRe = regexp.MustCompile(`^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$`)

// TestRedeemMembership:注册用户兑换 admin 生成的码 → 200,响应 tier=member,
// member_expires_at 非空,users 表 tier 落库为 member。
func TestRedeemMembership(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")
	codes := genAdminCodes(t, ts, db, 1, 30)

	rr := doReq(t, ts, http.MethodPost, "/api/v1/membership/redeem",
		fmt.Sprintf(`{"code":%q}`, codes[0]), token)
	if rr.Code != http.StatusOK {
		t.Fatalf("redeem: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		Tier            string `json:"tier"`
		MemberExpiresAt string `json:"member_expires_at"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse redeem: %v", err)
	}
	if resp.Tier != "member" || resp.MemberExpiresAt == "" {
		t.Fatalf("unexpected redeem response: %+v", resp)
	}
	var tier string
	if err := db.QueryRow(`SELECT tier FROM users WHERE id = ?`, uid).Scan(&tier); err != nil {
		t.Fatalf("query tier: %v", err)
	}
	if tier != "member" {
		t.Fatalf("users.tier = %q, want member", tier)
	}
}

// TestRedeemInvalidCode:不存在的码 → 400「兑换码无效或已被使用」。
func TestRedeemInvalidCode(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")

	rr := doReq(t, ts, http.MethodPost, "/api/v1/membership/redeem",
		`{"code":"XXXX-XXXX-XXXX"}`, token)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("invalid code: status=%d want 400 body=%s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), "兑换码无效或已被使用") {
		t.Fatalf("invalid code body=%s", rr.Body.String())
	}
}

// TestRedeemTwice:同一码兑换两次,第二次 400(已被使用)。
func TestRedeemTwice(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	codes := genAdminCodes(t, ts, db, 1, 30)

	rr := doReq(t, ts, http.MethodPost, "/api/v1/membership/redeem",
		fmt.Sprintf(`{"code":%q}`, codes[0]), token)
	if rr.Code != http.StatusOK {
		t.Fatalf("first redeem: status=%d body=%s", rr.Code, rr.Body.String())
	}
	rr = doReq(t, ts, http.MethodPost, "/api/v1/membership/redeem",
		fmt.Sprintf(`{"code":%q}`, codes[0]), token)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("second redeem: status=%d want 400 body=%s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), "已被使用") {
		t.Fatalf("second redeem body=%s", rr.Body.String())
	}
}

// TestRedeemStacks:连续兑换两个 30 天码,到期时间 = 第一次 + 60 天(叠加验证)。
func TestRedeemStacks(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	codes := genAdminCodes(t, ts, db, 2, 30)

	redeem := func(code string) string {
		t.Helper()
		rr := doReq(t, ts, http.MethodPost, "/api/v1/membership/redeem",
			fmt.Sprintf(`{"code":%q}`, code), token)
		if rr.Code != http.StatusOK {
			t.Fatalf("redeem %s: status=%d body=%s", code, rr.Code, rr.Body.String())
		}
		var resp struct {
			MemberExpiresAt string `json:"member_expires_at"`
		}
		if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
			t.Fatalf("parse redeem: %v", err)
		}
		return resp.MemberExpiresAt
	}

	first := redeem(codes[0])
	second := redeem(codes[1])

	// 第二次到期时间 ≈ now + 60 天(第一次 + 30 天叠加)。
	want := time.Now().UTC().AddDate(0, 0, 60)
	got, err := time.Parse("2006-01-02 15:04:05", second)
	if err != nil {
		t.Fatalf("parse second expiry %q: %v", second, err)
	}
	if diff := got.Sub(want); diff < -2*time.Minute || diff > 2*time.Minute {
		t.Fatalf("second expiry %s, want ~%s (first=%s)", second, want.Format("2006-01-02 15:04:05"), first)
	}
}

// TestAdminRedemptionCRUD:admin 生成(格式 XXXX-XXXX-XXXX、count 正确)、
// 列表含生成的码、删除未用码 204、删除已用码 400。
func TestAdminRedemptionCRUD(t *testing.T) {
	ts, db := newTestServer(t)
	admTok, _ := loginAdmin(t, ts, db, "root", "adminpass123")

	// 生成 3 个码,校验格式与数量
	rr := doReq(t, ts, http.MethodPost, "/api/v1/admin/redemption-codes",
		`{"count":3,"duration_days":30}`, admTok)
	if rr.Code != http.StatusCreated {
		t.Fatalf("gen codes: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var gen struct {
		Codes []string `json:"codes"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &gen); err != nil {
		t.Fatalf("parse gen: %v", err)
	}
	if len(gen.Codes) != 3 {
		t.Fatalf("codes count = %d, want 3", len(gen.Codes))
	}
	for _, c := range gen.Codes {
		if !codeRe.MatchString(c) {
			t.Fatalf("code %q not XXXX-XXXX-XXXX format", c)
		}
	}

	// 列表包含生成的码(分页对象 items 结构)
	rr = doReq(t, ts, http.MethodGet, "/api/v1/admin/redemption-codes", "", admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("list codes: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var list struct {
		Items []redemptionCodeJSON `json:"items"`
		Total int                  `json:"total"`
		Page  int                  `json:"page"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
		t.Fatalf("parse list: %v", err)
	}
	if len(list.Items) != 3 || list.Total != 3 || list.Page != 1 {
		t.Fatalf("list items=%d total=%d page=%d, want 3/3/1", len(list.Items), list.Total, list.Page)
	}
	found := false
	for _, c := range list.Items {
		if c.Code == gen.Codes[0] {
			found = true
		}
	}
	if !found {
		t.Fatalf("list missing generated code %s", gen.Codes[0])
	}

	// 删除未用码 -> 204
	rr = doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/admin/redemption-codes/%d", list.Items[0].ID), "", admTok)
	if rr.Code != http.StatusNoContent {
		t.Fatalf("delete unused: status=%d want 204 body=%s", rr.Code, rr.Body.String())
	}

	// 用户兑换一个码,再删除已用码 -> 400
	userTok := registerUser(t, ts, "bob")
	rr = doReq(t, ts, http.MethodPost, "/api/v1/membership/redeem",
		fmt.Sprintf(`{"code":%q}`, gen.Codes[1]), userTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("redeem for delete test: status=%d body=%s", rr.Code, rr.Body.String())
	}
	rr = doReq(t, ts, http.MethodGet, "/api/v1/admin/redemption-codes", "", admTok)
	var list2 struct {
		Items []redemptionCodeJSON `json:"items"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &list2); err != nil {
		t.Fatalf("parse list 2: %v", err)
	}
	var usedID int64
	for _, c := range list2.Items {
		if c.Code == gen.Codes[1] {
			usedID = c.ID
		}
	}
	if usedID == 0 {
		t.Fatalf("used code %s not in list", gen.Codes[1])
	}
	rr = doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/admin/redemption-codes/%d", usedID), "", admTok)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("delete used: status=%d want 400 body=%s", rr.Code, rr.Body.String())
	}
}

// TestMemberExpiryDowngrade:手动置为已过期会员 → GET /api/v1/me 返回 tier=free
// (syncMemberTier 生效)。
func TestMemberExpiryDowngrade(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")

	if _, err := db.Exec(`UPDATE users SET tier = 'member', member_expires_at = '2020-01-01' WHERE id = ?`, uid); err != nil {
		t.Fatalf("set expired member: %v", err)
	}
	rr := doReq(t, ts, http.MethodGet, "/api/v1/me", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("me: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		User struct {
			Tier string `json:"tier"`
		} `json:"user"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse me: %v", err)
	}
	if resp.User.Tier != "free" {
		t.Fatalf("tier = %q, want free (syncMemberTier 未生效)", resp.User.Tier)
	}
}
