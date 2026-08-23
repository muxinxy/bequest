package main

import (
	"database/sql"
	"errors"
	"log"
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
	if _, err := db.Exec(`INSERT INTO notification_quota (user_id, month, `+col+`) VALUES (?, ?, 1)
		ON CONFLICT(user_id, month) DO UPDATE SET `+col+` = `+col+` + 1`,
		uid, time.Now().Format("2006-01")); err != nil {
		log.Printf("quotaIncr: %v", err)
	}
}