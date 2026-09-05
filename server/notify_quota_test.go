package main

import (
	"testing"
	"time"
)

// TestNotificationQuotaGate:免费用户 email 默认额度 10,用满后拒绝;sms 对免费用户直接 false。
func TestNotificationQuotaGate(t *testing.T) {
	ts, db := newTestServer(t)
	_ = ts
	registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")

	if !quotaAllowed(db, uid, "free", "email") {
		t.Fatal("free user email quota should be allowed initially")
	}
	for i := 0; i < freeMonthlyEmails; i++ {
		quotaIncr(db, uid, "email")
	}
	if quotaAllowed(db, uid, "free", "email") {
		t.Fatal("free user email quota should be exhausted after freeMonthlyEmails increments")
	}
	if quotaAllowed(db, uid, "free", "sms") {
		t.Fatal("sms should be disallowed for free users")
	}
}

// TestMemberSmsQuota:会员 sms 有额度,用满 memberMonthlySms 次后拒绝。
func TestMemberSmsQuota(t *testing.T) {
	ts, db := newTestServer(t)
	_ = ts
	registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")
	if _, err := db.Exec(`UPDATE users SET tier = 'member' WHERE id = ?`, uid); err != nil {
		t.Fatalf("set tier member: %v", err)
	}

	if !quotaAllowed(db, uid, "member", "sms") {
		t.Fatal("member sms quota should be allowed initially")
	}
	for i := 0; i < memberMonthlySms; i++ {
		quotaIncr(db, uid, "sms")
	}
	if quotaAllowed(db, uid, "member", "sms") {
		t.Fatal("member sms quota should be exhausted after memberMonthlySms increments")
	}
}

// TestQuotaTableUpsert:同一用户同月 quotaIncr 两次 → notification_quota 该行 email_cnt=2。
func TestQuotaTableUpsert(t *testing.T) {
	ts, db := newTestServer(t)
	_ = ts
	registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")

	quotaIncr(db, uid, "email")
	quotaIncr(db, uid, "email")
	month := time.Now().Format("2006-01")
	var cnt int
	if err := db.QueryRow(`SELECT email_cnt FROM notification_quota WHERE user_id = ? AND month = ?`, uid, month).Scan(&cnt); err != nil {
		t.Fatalf("query quota row: %v", err)
	}
	if cnt != 2 {
		t.Fatalf("email_cnt = %d, want 2 (upsert 未生效)", cnt)
	}
}
