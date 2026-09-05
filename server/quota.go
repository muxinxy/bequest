package main

import (
	"database/sql"
	"errors"
	"log"
	"net/http"
	"time"
)

// quotaCol 返回 typ 对应的计数列(email_cnt / sms_cnt)。
func quotaCol(typ string) string {
	if typ == "sms" {
		return "sms_cnt"
	}
	return "email_cnt"
}

// quotaAllowed 判断该用户当月该渠道是否还有额度。
// email:免费/会员分别用 freeMonthlyEmails / memberMonthlyEmails;
// sms:仅会员,额度 memberMonthlySms,免费用户直接 false。
func quotaAllowed(db *sql.DB, uid int64, tier, typ string) bool {
	quota := 0
	switch typ {
	case "email":
		if tier == "member" {
			quota = memberMonthlyEmails
		} else {
			quota = freeMonthlyEmails
		}
	case "sms":
		if tier != "member" {
			return false
		}
		quota = memberMonthlySms
	default:
		return false
	}
	if quota <= 0 {
		return false
	}
	month := time.Now().Format("2006-01")
	var cnt int
	err := db.QueryRow(`SELECT `+quotaCol(typ)+` FROM notification_quota WHERE user_id = ? AND month = ?`,
		uid, month).Scan(&cnt)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		log.Printf("quotaAllowed: %v", err)
	}
	return cnt < quota
}

// quotaIncr 当月计数 +1(首次插入该月行)。
func quotaIncr(db *sql.DB, uid int64, typ string) {
	col := quotaCol(typ)
	var insertSQL string
	switch currentDialect {
	case dialectMySQL:
		// 重复键(user_id, month)命中时直接把计数 +1。
		insertSQL = `INSERT INTO notification_quota (user_id, month, ` + col + `) VALUES (?, ?, 1)
			ON DUPLICATE KEY UPDATE ` + col + ` = ` + col + ` + 1`
	case dialectPostgres:
		// PG 的 ON CONFLICT DO UPDATE 里裸列名在目标表与 excluded 之间歧义,
		// 需用表名限定。
		insertSQL = `INSERT INTO notification_quota (user_id, month, ` + col + `) VALUES (?, ?, 1)
			ON CONFLICT(user_id, month) DO UPDATE SET ` + col + ` = notification_quota.` + col + ` + 1`
	default:
		insertSQL = `INSERT INTO notification_quota (user_id, month, ` + col + `) VALUES (?, ?, 1)
			ON CONFLICT(user_id, month) DO UPDATE SET ` + col + ` = ` + col + ` + 1`
	}
	if _, err := db.Exec(insertSQL, uid, time.Now().Format("2006-01")); err != nil {
		log.Printf("quotaIncr: %v", err)
	}
}

// handleNotificationUsage: GET /api/v1/notification-usage -> 200
// 返回当月通知用量 vs 额度:{month, email_used, email_limit, sms_used, sms_limit, tier}。
func handleNotificationUsage(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var tier string
		if err := db.QueryRow(`SELECT tier FROM users WHERE id = ?`, uid).Scan(&tier); err != nil {
			log.Printf("usage tier: %v", err)
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
			log.Printf("usage query: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"month":       month,
			"email_used":  emailUsed,
			"email_limit": emailLimit,
			"sms_used":    smsUsed,
			"sms_limit":   smsLimit,
			"tier":        tier,
		})
	}
}
