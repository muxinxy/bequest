package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
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
// makes re-runs no-ops (ON CONFLICT DO NOTHING / INSERT IGNORE on MySQL).
// Returns true when a new row was actually inserted (callers use it to gate
// once-per-day sends).
func insertReminder(db *sql.DB, uid int64, rtype string, assetID *int64, title, body, dedup string) bool {
	var insertSQL string
	if currentDialect == dialectMySQL {
		insertSQL = `INSERT IGNORE INTO reminders (user_id, type, asset_id, title, body, dedup_key) VALUES (?, ?, ?, ?, ?, ?)`
	} else {
		insertSQL = `INSERT INTO reminders (user_id, type, asset_id, title, body, dedup_key) VALUES (?, ?, ?, ?, ?, ?)
			ON CONFLICT(user_id, dedup_key) DO NOTHING`
	}
	res, err := db.Exec(insertSQL, uid, rtype, assetID, title, body, dedup)
	if err != nil {
		log.Printf("insert reminder: %v", err)
		return false
	}
	n, _ := res.RowsAffected()
	return n > 0
}

// ---------- expiry ----------

var expiryAdvances = []int{30, 7, 1}

// processExpiryReminders emits one reminder per asset per matched advance
// window (30/7/1 days before expiry) plus a single "已到期" reminder once an
// asset is past its expiry date.
func processExpiryReminders(db *sql.DB, now time.Time) {
	rows, err := db.Query(`SELECT a.id, a.user_id, a.name, a.expiry_date, u.tier
		FROM assets a JOIN users u ON u.id = a.user_id
		WHERE a.expiry_date IS NOT NULL AND a.expiry_date != ''`)
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
		tier string
	}
	var assets []assetRow
	for rows.Next() {
		var a assetRow
		if err := rows.Scan(&a.id, &a.uid, &a.name, &a.exp, &a.tier); err != nil {
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
					title, body := renderTemplate(db, a.uid, "expiry",
						map[string]string{"name": a.name, "date": a.exp, "days": fmt.Sprint(daysLeft)})
					if title == "" { // 模板缺失:回退硬编码(按用户语言偏好)
						lang := userLang(db, a.uid)
						title = fmt.Sprintf(userMsg(lang, "资产「%s」即将到期"), a.name)
						body = fmt.Sprintf(userMsg(lang, "您的资产 %s 将于 %s 到期,剩余 %d 天,请及时处理续费或迁移。"), a.name, a.exp, daysLeft)
					}
					notifyUser(db, a.uid, a.tier, "expiry", title, body, fmt.Sprintf("exp:%d:%d", a.id, adv))
				}
			}
		} else {
			title, body := renderTemplate(db, a.uid, "expiry",
				map[string]string{"name": a.name, "date": a.exp})
			if title == "" {
				lang := userLang(db, a.uid)
				title = fmt.Sprintf(userMsg(lang, "资产「%s」已到期"), a.name)
				body = fmt.Sprintf(userMsg(lang, "您的资产 %s 已于 %s 到期,请及时处理续费或迁移。"), a.name, a.exp)
			}
			notifyUser(db, a.uid, a.tier, "expiry", title, body, fmt.Sprintf("exp:%d:past", a.id))
		}
	}
}

// ---------- escalation & inheritance trigger ----------

// 触发阶梯 2 级:一级 IM+邮件,二级 一级+短信。跨过最后一档触发继承。
// 默认 [15, 60]:15 天一级提醒,60 天二级升级并触发继承;管理员可在
// config.json 配 default_ladder_days 覆盖(见 config.go defaultLadderConfig)。

// userLadderDays 返回该用户全局触发阶梯的 days(JSON 解析);
// 无全局阶梯时回退默认配置 defaultLadderConfig。
func userLadderDays(db *sql.DB, uid int64, tier string) []int {
	var days string
	if err := db.QueryRow(`SELECT days FROM trigger_ladders WHERE user_id = ? AND is_global = 1`, uid).Scan(&days); err == nil {
		var d []int
		if json.Unmarshal([]byte(days), &d) == nil && len(d) > 0 {
			return d
		}
	}
	return defaultLadderConfig
}

// processEscalation walks inactive users; the reported level is 1-based
// (number of tiers crossed), capped at len(thresholds)-1 because crossing the
// final tier is the inheritance trigger, not a distinct level.
func processEscalation(db *sql.DB, now time.Time) {
	rows, err := db.Query(`SELECT id, tier, escalation_level, last_login_at
		FROM users WHERE last_login_at IS NOT NULL AND last_login_at != ''
			AND inheritance_enabled = 1`) // 继承开关关闭:跳过升级/触发
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
	}
	var users []userRow
	for rows.Next() {
		var u userRow
		if err := rows.Scan(&u.id, &u.tier, &u.level, &u.lastLogin); err != nil {
			log.Printf("scan user: %v", err)
			return
		}
		users = append(users, u)
	}
	rows.Close()

	for _, u := range users {
		thresholds := userLadderDays(db, u.id, u.tier)
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
			}
		}
		// 分级通知(系统/邮件/短信),dedup 按天防刷屏。
		notifyEscalation(db, u.id, u.tier, daysSince, thresholds)
		if idx >= len(thresholds)-1 {
			triggerInheritance(db, u.id, daysSince)
		}
	}
}

// triggerInheritance creates pending inheritance events for a user at the top
// escalation tier. Assets with per-asset inheritors (asset_inheritors) get
// individual events bound to their designated inheritor (asset_key_wrapped_wk
// is handed over on claim); assets without configuration fall back to the
// user-level event that releases master_key_wrapped.
func triggerInheritance(db *sql.DB, uid int64, daysSince int) {
	// Per-asset events: for each asset-inheritor binding whose trigger condition
	// is met (trigger_days NULL = use the global escalation line already reached).
	rows, err := db.Query(`SELECT ai.asset_id, ai.inheritor_id, i.email, i.access_code_hash, ai.trigger_days
		FROM asset_inheritors ai
		JOIN inheritors i ON i.id = ai.inheritor_id
		JOIN assets a ON a.id = ai.asset_id
		WHERE a.user_id = ? AND a.status = 'active' ORDER BY ai.priority ASC, ai.id ASC`, uid)
	if err != nil {
		log.Printf("query asset inheritors: %v", err)
		return
	}
	defer rows.Close()
	type binding struct {
		assetID, inID   int64
		email, codeHash string
		triggerDays     *int
	}
	bindings := []binding{}
	for rows.Next() {
		var b binding
		var td sql.NullInt64
		if err := rows.Scan(&b.assetID, &b.inID, &b.email, &b.codeHash, &td); err != nil {
			log.Printf("scan asset inheritor: %v", err)
			continue
		}
		if td.Valid {
			n := int(td.Int64)
			b.triggerDays = &n
		}
		bindings = append(bindings, b)
	}
	// 每资产一个 live 事件(按 asset_id 计);触发天数:独立配置优先,否则用全局已跨过的线。
	boundAssets := map[int64]bool{}
	for _, b := range bindings {
		boundAssets[b.assetID] = true
		if b.triggerDays != nil && daysSince < *b.triggerDays {
			continue
		}
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM inheritance_events
			WHERE user_id = ? AND asset_id = ? AND status IN ('pending','claimed')`, uid, b.assetID).
			Scan(&n); err != nil {
			log.Printf("count asset events: %v", err)
			continue
		}
		if n > 0 {
			continue
		}
		createInheritanceEvent(db, uid, b.inID, b.email, b.codeHash, &b.assetID)
	}
	// 分组级继承:资产无资产级绑定时,按所属分组的 category_inheritors 交接
	// (该分组下所有未单独绑定的资产继承分组继承人)。
	catRows, err := db.Query(`SELECT a.id, ci.inheritor_id, i.email, i.access_code_hash, ci.trigger_days
		FROM category_inheritors ci
		JOIN inheritors i ON i.id = ci.inheritor_id
		JOIN assets a ON a.category_id = ci.category_id
		WHERE a.user_id = ? AND a.status = 'active' AND NOT EXISTS (
			SELECT 1 FROM asset_inheritors ai WHERE ai.asset_id = a.id
		) ORDER BY ci.priority ASC, ci.id ASC, a.id ASC`, uid)
	if err != nil {
		log.Printf("query category inheritors: %v", err)
		return
	}
	defer catRows.Close()
	for catRows.Next() {
		var assetID, inID int64
		var email, codeHash string
		var td sql.NullInt64
		if err := catRows.Scan(&assetID, &inID, &email, &codeHash, &td); err != nil {
			log.Printf("scan category inheritor: %v", err)
			continue
		}
		if td.Valid && daysSince < int(td.Int64) {
			continue
		}
		if boundAssets[assetID] {
			continue
		}
		boundAssets[assetID] = true
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM inheritance_events
			WHERE user_id = ? AND asset_id = ? AND status IN ('pending','claimed')`, uid, assetID).
			Scan(&n); err != nil {
			log.Printf("count asset events: %v", err)
			continue
		}
		if n == 0 {
			createInheritanceEvent(db, uid, inID, email, codeHash, &assetID)
		}
	}
	catRows.Close()
	// 全量事件:仅当存在未配置继承人绑定的资产(或完全无绑定)时才建。
	// 有资产级/分组级配置的资产已单独建事件,不再进全量。
	configured := len(boundAssets)
	var total int
	if err := db.QueryRow(`SELECT COUNT(*) FROM assets WHERE user_id = ? AND status = 'active'`, uid).Scan(&total); err != nil {
		log.Printf("count assets: %v", err)
		return
	}
	if configured >= total && total > 0 {
		return
	}
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM inheritance_events WHERE user_id = ? AND asset_id IS NULL AND status IN ('pending','claimed')`, uid).
		Scan(&n); err != nil {
		log.Printf("count inheritance events: %v", err)
		return
	}
	if n > 0 {
		return // one live global event per user
	}
	// 用户级全量事件:优先用默认继承人;未设置(或指向已删除继承人)时回退第一顺位。
	var inID int64
	var inEmail, codeHash string
	var defID sql.NullInt64
	if err := db.QueryRow(`SELECT default_inheritor_id FROM users WHERE id = ?`, uid).Scan(&defID); err == nil && defID.Valid {
		err = db.QueryRow(`SELECT id, email, access_code_hash FROM inheritors
			WHERE id = ? AND user_id = ?`, defID.Int64, uid).
			Scan(&inID, &inEmail, &codeHash)
		if err == nil {
			createInheritanceEvent(db, uid, inID, inEmail, codeHash, nil)
			return
		}
	}
	err = db.QueryRow(`SELECT id, email, access_code_hash FROM inheritors
		WHERE user_id = ? ORDER BY priority ASC, id ASC LIMIT 1`, uid).
		Scan(&inID, &inEmail, &codeHash)
	if errors.Is(err, sql.ErrNoRows) {
		return // no inheritors -> nothing to hand over
	}
	if err != nil {
		log.Printf("query first inheritor: %v", err)
		return
	}
	createInheritanceEvent(db, uid, inID, inEmail, codeHash, nil)
}

// createInheritanceEvent inserts one event, snapshots the inheritor's access
// code hash, sets stage, notifies owner and emails the inheritor.
// 语义确认:无论资产级/分组级/用户级事件,这里统一把 inherit_stage 置为
// 'triggered'——资产级事件同样会推进全局触发阶段(阶段是用户级状态,只进不退)。
func createInheritanceEvent(db *sql.DB, uid, inID int64, inEmail, codeHash string, assetID *int64) {
	keyBytes := make([]byte, 16)
	if _, err := rand.Read(keyBytes); err != nil {
		log.Printf("random event key: %v", err)
		return
	}
	eventKey := hex.EncodeToString(keyBytes)
	if _, err := db.Exec(`INSERT INTO inheritance_events (user_id, inheritor_id, event_key, access_code_hash, asset_id)
		VALUES (?, ?, ?, ?, ?)`, uid, inID, eventKey, codeHash, assetID); err != nil {
		log.Printf("insert inheritance event: %v", err)
		return
	}
	if _, err := db.Exec(`UPDATE users SET inherit_stage = 'triggered' WHERE id = ?`, uid); err != nil {
		log.Printf("set triggered stage: %v", err)
	}
	assetNote := ""
	assetName := ""
	// 交接文案按资产所有者的语言偏好(继承人是外部联系人,无账号语言)。
	lang := userLang(db, uid)
	if assetID != nil {
		var name string
		if err := db.QueryRow(`SELECT name FROM assets WHERE id = ?`, *assetID).Scan(&name); err == nil {
			assetName = name
			assetNote = userMsg(lang, " (资产: ") + name + ")"
		}
	}
	title, body := renderTemplate(db, uid, "inheritance", map[string]string{"name": assetName})
	if title == "" { // 模板缺失:回退硬编码(按用户语言偏好)
		title = userMsg(lang, "继承交接已触发") + assetNote
		body = userMsg(lang, "继承交接已触发,事件密钥: ") + eventKey
	}
	insertReminder(db, uid, "inheritance", assetID, title, body, fmt.Sprintf("inherit:%d:%v", uid, assetID))
	// event_key is written to the audit detail so it stays retrievable in dev
	// (and emailed to the inheritor when SMTP is configured).
	if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (?, 'system', 'inheritance_triggered', ?)`,
		uid, "event_key="+eventKey+assetNote); err != nil {
		log.Printf("audit trigger: %v", err)
	}
	sendMail(inEmail, "托孤: "+userMsg(lang, "继承交接已触发")+assetNote,
		fmt.Sprintf(userMsg(lang, "继承交接已触发。事件密钥: %s\n请通过 App/API 使用该密钥与您的访问码完成继承领取。"), eventKey))
}
