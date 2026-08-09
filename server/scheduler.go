package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"time"
)

// scan runs one full dead-man's-switch pass over the DB. Pure-ish: no
// globals, all state lives in the database, so it is directly testable.
func scan(db *sql.DB, now time.Time) {
	now = now.UTC()
	processExpiryReminders(db, now)
	processEscalation(db, now)
}

// insertReminder inserts a reminder; the UNIQUE(user_id, dedup_key) index
// makes re-runs no-ops (ON CONFLICT DO NOTHING).
func insertReminder(db *sql.DB, uid int64, rtype string, assetID *int64, title, body, dedup string) {
	if _, err := db.Exec(`INSERT INTO reminders (user_id, type, asset_id, title, body, dedup_key) VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(user_id, dedup_key) DO NOTHING`, uid, rtype, assetID, title, body, dedup); err != nil {
		log.Printf("insert reminder: %v", err)
	}
}

// ---------- expiry ----------

var expiryAdvances = []int{30, 7, 1}

// processExpiryReminders emits one reminder per asset per matched advance
// window (30/7/1 days before expiry) plus a single "已到期" reminder once an
// asset is past its expiry date.
func processExpiryReminders(db *sql.DB, now time.Time) {
	rows, err := db.Query(`SELECT id, user_id, name, expiry_date FROM assets WHERE expiry_date IS NOT NULL AND expiry_date != ''`)
	if err != nil {
		log.Printf("query assets for expiry: %v", err)
		return
	}
	defer rows.Close()
	type assetRow struct {
		id   int64
		uid  int64
		name string
		exp  string
	}
	var assets []assetRow
	for rows.Next() {
		var a assetRow
		if err := rows.Scan(&a.id, &a.uid, &a.name, &a.exp); err != nil {
			log.Printf("scan asset: %v", err)
			return
		}
		assets = append(assets, a)
	}
	rows.Close()

	for _, a := range assets {
		expDate, err := time.Parse("2006-01-02", a.exp)
		if err != nil {
			continue // unparseable date -> skip
		}
		if expDate.After(now) {
			daysLeft := int(expDate.Sub(now).Hours() / 24)
			for _, adv := range expiryAdvances {
				if !expDate.After(now.AddDate(0, 0, adv)) {
					title := fmt.Sprintf("资产「%s」即将到期", a.name)
					body := fmt.Sprintf("您的资产 %s 将于 %s 到期,剩余 %d 天,请及时处理续费或迁移。", a.name, a.exp, daysLeft)
					insertReminder(db, a.uid, "expiry", &a.id, title, body, fmt.Sprintf("exp:%d:%d", a.id, adv))
				}
			}
		} else {
			title := fmt.Sprintf("资产「%s」已到期", a.name)
			body := fmt.Sprintf("您的资产 %s 已于 %s 到期,请及时处理续费或迁移。", a.name, a.exp)
			insertReminder(db, a.uid, "expiry", &a.id, title, body, fmt.Sprintf("exp:%d:past", a.id))
		}
	}
}

// ---------- escalation & inheritance trigger ----------

var escalationTiers = map[string][]int{
	"free":   {30, 60, 90, 120},
	"member": {7, 14, 30, 60},
}

// processEscalation walks inactive users; the reported level is 1-based
// (number of tiers crossed), capped at len(thresholds)-1 because crossing the
// final tier is the inheritance trigger, not a distinct level.
func processEscalation(db *sql.DB, now time.Time) {
	rows, err := db.Query(`SELECT id, tier, escalation_level, last_login_at, email
		FROM users WHERE last_login_at IS NOT NULL AND last_login_at != ''`)
	if err != nil {
		log.Printf("query users for escalation: %v", err)
		return
	}
	defer rows.Close()
	type userRow struct {
		id        int64
		tier      string
		level     int
		lastLogin string
		email     string
	}
	var users []userRow
	for rows.Next() {
		var u userRow
		if err := rows.Scan(&u.id, &u.tier, &u.level, &u.lastLogin, &u.email); err != nil {
			log.Printf("scan user: %v", err)
			return
		}
		users = append(users, u)
	}
	rows.Close()

	for _, u := range users {
		thresholds, ok := escalationTiers[u.tier]
		if !ok {
			thresholds = escalationTiers["free"]
		}
		lt, err := time.Parse("2006-01-02 15:04:05", u.lastLogin)
		if err != nil {
			continue
		}
		daysSince := int(now.Sub(lt).Hours() / 24)
		idx := -1
		for i, th := range thresholds {
			if daysSince >= th {
				idx = i
			}
		}
		if idx < 0 {
			continue
		}
		level := idx + 1
		if level > len(thresholds)-1 {
			level = len(thresholds) - 1
		}
		if level > u.level {
			if _, err := db.Exec(`UPDATE users SET escalation_level = ? WHERE id = ?`, level, u.id); err != nil {
				log.Printf("update escalation: %v", err)
				continue
			}
			body := fmt.Sprintf("您已 %d 天未登录,资产安全提醒升级。", daysSince)
			insertReminder(db, u.id, "escalation", nil, "长时间未登录提醒", body, fmt.Sprintf("esc:%d:%d", u.id, level))
			if level >= 2 && u.email != "" {
				sendMail(u.email, "资产安全提醒升级",
					fmt.Sprintf("您已 %d 天未登录,资产安全提醒升级,请尽快登录以确认仍在世。", daysSince))
			}
		}
		if idx >= len(thresholds)-1 {
			triggerInheritance(db, u.id)
		}
	}
}

// triggerInheritance creates a single pending inheritance event for a user at
// the top escalation tier. The event snapshots the first inheritor's stored
// access-code hash (the scheduler never sees the plaintext code).
func triggerInheritance(db *sql.DB, uid int64) {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM inheritance_events WHERE user_id = ? AND status IN ('pending','claimed')`, uid).
		Scan(&n); err != nil {
		log.Printf("count inheritance events: %v", err)
		return
	}
	if n > 0 {
		return // one live event per user
	}
	var inID int64
	var inEmail, codeHash string
	err := db.QueryRow(`SELECT id, email, access_code_hash FROM inheritors
		WHERE user_id = ? ORDER BY priority ASC, id ASC LIMIT 1`, uid).
		Scan(&inID, &inEmail, &codeHash)
	if errors.Is(err, sql.ErrNoRows) {
		return // no inheritors -> nothing to hand over
	}
	if err != nil {
		log.Printf("query first inheritor: %v", err)
		return
	}
	keyBytes := make([]byte, 16)
	if _, err := rand.Read(keyBytes); err != nil {
		log.Printf("random event key: %v", err)
		return
	}
	eventKey := hex.EncodeToString(keyBytes)
	if _, err := db.Exec(`INSERT INTO inheritance_events (user_id, inheritor_id, event_key, access_code_hash)
		VALUES (?, ?, ?, ?)`, uid, inID, eventKey, codeHash); err != nil {
		log.Printf("insert inheritance event: %v", err)
		return
	}
	if _, err := db.Exec(`UPDATE users SET inherit_stage = 'triggered' WHERE id = ?`, uid); err != nil {
		log.Printf("set triggered stage: %v", err)
	}
	insertReminder(db, uid, "inheritance", nil, "继承交接已触发",
		"继承交接已触发,事件密钥: "+eventKey, fmt.Sprintf("inherit:%d", uid))
	// event_key is written to the audit detail so it stays retrievable in dev
	// (and emailed to the inheritor when SMTP is configured).
	if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (?, 'system', 'inheritance_triggered', ?)`,
		uid, "event_key="+eventKey); err != nil {
		log.Printf("audit trigger: %v", err)
	}
	sendMail(inEmail, "托孤: 继承交接已触发",
		fmt.Sprintf("继承交接已触发。事件密钥: %s\n请通过 App/API 使用该密钥与您的访问码完成继承领取。", eventKey))
}
