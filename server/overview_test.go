package main

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

// TestOverview: 注册用户 → 造资产(不同 status、1 个 10 天后到期、1 个已过期)、
// 分组、继承人、阶梯、提醒 → GET /overview → 断言各字段正确。
func TestOverview(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")

	// 资产:active x2、inactive x1、pending x1、expired x1(已过期,也在预警内)、
	// 1 个 10 天后到期(active,预警内)、1 个 60 天后到期(active,预警外)。
	insertAsset := func(name, status, expiry string) {
		t.Helper()
		var exp any
		if expiry != "" {
			exp = expiry
		}
		if _, err := db.Exec(`INSERT INTO assets (user_id, asset_type, name, encrypted_data, expiry_date, status)
			VALUES (?, 'virtual', ?, ?, ?, ?)`, uid, name, []byte{0}, exp, status); err != nil {
			t.Fatalf("insert asset %s: %v", name, err)
		}
	}
	insertAsset("a-active-1", "active", "")
	insertAsset("a-active-2", "active", "")
	insertAsset("a-inactive", "inactive", "")
	insertAsset("a-pending", "pending", "")
	insertAsset("a-expired", "expired", time.Now().AddDate(0, 0, -5).Format("2006-01-02"))
	insertAsset("a-soon", "active", time.Now().AddDate(0, 0, 10).Format("2006-01-02"))
	insertAsset("a-later", "active", time.Now().AddDate(0, 0, 60).Format("2006-01-02"))

	// 注册自动建预设分组 + 全局阶梯,先记基线,再插入增量。
	var baseCat, baseLadder int
	if err := db.QueryRow(`SELECT COUNT(*) FROM categories WHERE user_id = ? AND deleted_at IS NULL`, uid).Scan(&baseCat); err != nil {
		t.Fatalf("base categories: %v", err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM trigger_ladders WHERE user_id = ?`, uid).Scan(&baseLadder); err != nil {
		t.Fatalf("base ladders: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO categories (user_id, name) VALUES (?, 'cat1'), (?, 'cat2')`, uid, uid); err != nil {
		t.Fatalf("insert categories: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO inheritors (user_id, name, email, access_code_hash) VALUES (?, 'ih1', 'ih1@e.com', 'h'), (?, 'ih2', 'ih2@e.com', 'h'), (?, 'ih3', 'ih3@e.com', 'h')`, uid, uid, uid); err != nil {
		t.Fatalf("insert inheritors: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO trigger_ladders (user_id, name, days) VALUES (?, 'c1', '[60]'), (?, 'c2', '[90]'), (?, 'c3', '[120]')`, uid, uid, uid); err != nil {
		t.Fatalf("insert ladders: %v", err)
	}

	// 提醒:2 条未读 + 1 条已读。
	if _, err := db.Exec(`INSERT INTO reminders (user_id, type, title, body, dedup_key, status)
		VALUES (?, 'expiry', 'r1', 'b', 'k1', 'pending'), (?, 'expiry', 'r2', 'b', 'k2', 'pending'), (?, 'expiry', 'r3', 'b', 'k3', 'read')`, uid, uid, uid); err != nil {
		t.Fatalf("insert reminders: %v", err)
	}

	rr := doReq(t, ts, http.MethodGet, "/api/v1/overview", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("overview status=%d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		Assets struct {
			Total        int `json:"total"`
			Active       int `json:"active"`
			Inactive     int `json:"inactive"`
			Pending      int `json:"pending"`
			Expired      int `json:"expired"`
			ExpiringSoon []struct {
				ID         int64  `json:"id"`
				Name       string `json:"name"`
				ExpiryDate string `json:"expiry_date"`
				Status     string `json:"status"`
			} `json:"expiring_soon"`
		} `json:"assets"`
		Counts struct {
			Categories     int `json:"categories"`
			Inheritors     int `json:"inheritors"`
			TriggerLadders int `json:"trigger_ladders"`
		} `json:"counts"`
		Reminders struct {
			Unread int `json:"unread"`
			Recent []struct {
				ID    int64  `json:"id"`
				Type  string `json:"type"`
				Title string `json:"title"`
			} `json:"recent"`
		} `json:"reminders"`
		Quota struct {
			EmailUsed  int    `json:"email_used"`
			EmailLimit int    `json:"email_limit"`
			SmsUsed    int    `json:"sms_used"`
			SmsLimit   int    `json:"sms_limit"`
			Month      string `json:"month"`
		} `json:"quota"`
		Membership struct {
			Tier            string `json:"tier"`
			MemberExpiresAt string `json:"member_expires_at"`
		} `json:"membership"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse overview: %v body=%s", err, rr.Body.String())
	}

	// 资产统计:7 条,active=4(2+soon+later)、inactive=1、pending=1、expired=1。
	if resp.Assets.Total != 7 || resp.Assets.Active != 4 || resp.Assets.Inactive != 1 ||
		resp.Assets.Pending != 1 || resp.Assets.Expired != 1 {
		t.Fatalf("assets stats=%+v want total=7 active=4 inactive=1 pending=1 expired=1", resp.Assets)
	}
	// 到期预警:已过期 + 10 天后到期,共 2 条,按到期日升序(已过期在前)。
	if len(resp.Assets.ExpiringSoon) != 2 {
		t.Fatalf("expiring_soon len=%d want 2: %+v", len(resp.Assets.ExpiringSoon), resp.Assets.ExpiringSoon)
	}
	if resp.Assets.ExpiringSoon[0].Name != "a-expired" || resp.Assets.ExpiringSoon[1].Name != "a-soon" {
		t.Fatalf("expiring_soon order=%+v want [a-expired, a-soon]", resp.Assets.ExpiringSoon)
	}

	// 计数:基线 + 增量(categories +2、inheritors +3、ladders +3)。
	if resp.Counts.Categories != baseCat+2 || resp.Counts.Inheritors != 3 || resp.Counts.TriggerLadders != baseLadder+3 {
		t.Fatalf("counts=%+v want categories=%d inheritors=3 ladders=%d", resp.Counts, baseCat+2, baseLadder+3)
	}

	// 提醒:未读 2,最近 3 条(id DESC:r3,r2,r1)。
	if resp.Reminders.Unread != 2 || len(resp.Reminders.Recent) != 3 {
		t.Fatalf("reminders unread=%d recent=%d want 2/3", resp.Reminders.Unread, len(resp.Reminders.Recent))
	}
	if resp.Reminders.Recent[0].Title != "r3" || resp.Reminders.Recent[2].Title != "r1" {
		t.Fatalf("recent order=%+v want [r3,r2,r1]", resp.Reminders.Recent)
	}

	// 额度:免费用户 email_limit=freeMonthlyEmails、sms_limit=0,当月。
	if resp.Quota.EmailLimit != freeMonthlyEmails || resp.Quota.SmsLimit != 0 || resp.Quota.EmailUsed != 0 {
		t.Fatalf("quota=%+v want email_limit=%d sms_limit=0", resp.Quota, freeMonthlyEmails)
	}
	if resp.Quota.Month != time.Now().Format("2006-01") {
		t.Fatalf("quota month=%s want %s", resp.Quota.Month, time.Now().Format("2006-01"))
	}

	// 会员:免费用户 tier=free、member_expires_at 空串。
	if resp.Membership.Tier != "free" || resp.Membership.MemberExpiresAt != "" {
		t.Fatalf("membership=%+v want tier=free expires=''", resp.Membership)
	}
}
