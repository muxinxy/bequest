package main

import (
	"database/sql"
	"errors"
	"log"
	"net/http"
	"time"
)

// expiringSoonAsset 30 天内到期(含已过期)的资产条目。
type expiringSoonAsset struct {
	ID         int64  `json:"id"`
	Name       string `json:"name"`
	ExpiryDate string `json:"expiry_date"`
	Status     string `json:"status"`
}

// recentReminder 最近提醒条目。
type recentReminder struct {
	ID        int64  `json:"id"`
	Type      string `json:"type"`
	Title     string `json:"title"`
	CreatedAt string `json:"created_at"`
}

// handleOverview: GET /api/v1/overview -> 200
// 登录后总览聚合:资产统计/到期预警、分类/继承人/阶梯计数、提醒、当月额度、会员信息。
func handleOverview(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)

		// 资产:按 status 分组计数(排除回收站)。
		assets := map[string]int{"active": 0, "inactive": 0, "pending": 0, "expired": 0}
		total := 0
		rows, err := db.Query(`SELECT status, COUNT(*) FROM assets
			WHERE user_id = ? AND deleted_at IS NULL GROUP BY status`, uid)
		if err != nil {
			log.Printf("overview assets: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		for rows.Next() {
			var st string
			var n int
			if err := rows.Scan(&st, &n); err != nil {
				rows.Close()
				log.Printf("overview scan assets: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			assets[st] = n
			total += n
		}
		rows.Close()

		// 到期预警:expiry_date 非空且 <= 30 天后(含已到期),按到期日升序,最多 10 条。
		cutoff := time.Now().AddDate(0, 0, 30).Format("2006-01-02")
		expRows, err := db.Query(`SELECT id, name, expiry_date, status FROM assets
			WHERE user_id = ? AND deleted_at IS NULL AND expiry_date IS NOT NULL AND expiry_date <= ?
			ORDER BY expiry_date LIMIT 10`, uid, cutoff)
		if err != nil {
			log.Printf("overview expiring: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		expiring := []expiringSoonAsset{}
		for expRows.Next() {
			var a expiringSoonAsset
			if err := expRows.Scan(&a.ID, &a.Name, &a.ExpiryDate, &a.Status); err != nil {
				expRows.Close()
				log.Printf("overview scan expiring: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			expiring = append(expiring, a)
		}
		expRows.Close()

		// 分类/继承人/阶梯计数。
		var catCnt, inhCnt, ladderCnt int
		if err := db.QueryRow(`SELECT
			(SELECT COUNT(*) FROM categories WHERE user_id = ? AND deleted_at IS NULL),
			(SELECT COUNT(*) FROM inheritors WHERE user_id = ?),
			(SELECT COUNT(*) FROM trigger_ladders WHERE user_id = ?)`, uid, uid, uid).
			Scan(&catCnt, &inhCnt, &ladderCnt); err != nil {
			log.Printf("overview counts: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}

		// 提醒:未读数 + 最近 3 条。
		var unread int
		if err := db.QueryRow(`SELECT COUNT(*) FROM reminders WHERE user_id = ? AND status = 'pending'`, uid).Scan(&unread); err != nil {
			log.Printf("overview unread: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		remRows, err := db.Query(`SELECT id, type, title, created_at FROM reminders
			WHERE user_id = ? ORDER BY id DESC LIMIT 3`, uid)
		if err != nil {
			log.Printf("overview reminders: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		recent := []recentReminder{}
		for remRows.Next() {
			var rem recentReminder
			if err := remRows.Scan(&rem.ID, &rem.Type, &rem.Title, &rem.CreatedAt); err != nil {
				remRows.Close()
				log.Printf("overview scan reminders: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			recent = append(recent, rem)
		}
		remRows.Close()

		// 会员信息 + 当月额度(复用 handleNotificationUsage 的额度逻辑)。
		var tier string
		var memberExpires sql.NullString
		if err := db.QueryRow(`SELECT tier, member_expires_at FROM users WHERE id = ?`, uid).
			Scan(&tier, &memberExpires); err != nil {
			log.Printf("overview user: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		emailLimit, smsLimit := freeMonthlyEmails, 0
		if tier == "member" {
			emailLimit = memberMonthlyEmails
			smsLimit = memberMonthlySms
		}
		month := time.Now().Format("2006-01")
		var emailUsed, smsUsed int
		if err := db.QueryRow(`SELECT email_cnt, sms_cnt FROM notification_quota WHERE user_id = ? AND month = ?`,
			uid, month).Scan(&emailUsed, &smsUsed); err != nil && !errors.Is(err, sql.ErrNoRows) {
			log.Printf("overview quota: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		memberExpiresAt := ""
		if memberExpires.Valid {
			memberExpiresAt = memberExpires.String
		}

		writeJSON(w, http.StatusOK, map[string]any{
			"assets": map[string]any{
				"total":         total,
				"active":        assets["active"],
				"inactive":      assets["inactive"],
				"pending":       assets["pending"],
				"expired":       assets["expired"],
				"expiring_soon": expiring,
			},
			"counts": map[string]int{
				"categories":      catCnt,
				"inheritors":      inhCnt,
				"trigger_ladders": ladderCnt,
			},
			"reminders": map[string]any{
				"unread": unread,
				"recent": recent,
			},
			"quota": map[string]any{
				"email_used":  emailUsed,
				"email_limit": emailLimit,
				"sms_used":    smsUsed,
				"sms_limit":   smsLimit,
				"month":       month,
			},
			"membership": map[string]string{
				"tier":              tier,
				"member_expires_at": memberExpiresAt,
			},
		})
	}
}
