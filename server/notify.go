package main

import (
	"database/sql"
	"errors"
	"fmt"
	"log"
	"time"
)

// notifyUser is the single dispatch point for user-facing reminders:
// in-app (reminders table, dedup key as today), email via the user's own
// SMTP when configured (falling back to system SMTP), and — members only —
// the SMS channel. 邮件/短信走通知渠道列表;系统发送受月度额度限制。
func notifyUser(db *sql.DB, uid int64, tier, typ, title, body, dedup string) {
	insertReminder(db, uid, typ, nil, title, body, dedup)
	for _, to := range userEmails(db, uid) {
		if sendCustomForUser(db, uid, to, title, body) {
			continue // 用户自定义 SMTP 成功:不计系统额度
		}
		if quotaAllowed(db, uid, tier, "email") {
			sendMail(to, title, body)
			quotaIncr(db, uid, "email")
		} else {
			log.Printf("notifyUser: email quota exceeded for user %d", uid)
		}
	}
	if tier == "member" {
		for _, phone := range userPhones(db, uid) {
			if quotaAllowed(db, uid, tier, "sms") {
				sendSMS(db, phone, body)
				quotaIncr(db, uid, "sms")
			} else {
				log.Printf("notifyUser: sms quota exceeded for user %d", uid)
			}
		}
	}
}

// sendCustomForUser sends via the recipient user's own SMTP server when a row
// exists, is enabled and has a host; returns true only when the send actually
// succeeded (so the caller skips the system sender). Missing/disabled config
// or a failed send falls back to the system sender.
func sendCustomForUser(db *sql.DB, uid int64, to, subject, body string) bool {
	var host, user, from string
	var port, enabled int
	var enc []byte
	err := db.QueryRow(`SELECT host, port, user, password_enc, from_addr, enabled FROM user_smtp WHERE user_id = ?`, uid).
		Scan(&host, &port, &user, &enc, &from, &enabled)
	if errors.Is(err, sql.ErrNoRows) || host == "" || enabled == 0 {
		return false
	}
	if err != nil {
		log.Printf("notifyUser: query user smtp: %v", err)
		return false
	}
	pass, err := decryptSecret(enc)
	if err != nil {
		log.Printf("notifyUser: decrypt smtp password: %v", err)
		return false
	}
	if err := sendMailCustom(smtpServer{Host: host, Port: port, User: user, Password: pass, FromAddr: from}, to, subject, body); err != nil {
		// 发送失败(认证/网络/配置失效):回退系统 SMTP,不吞错误。
		log.Printf("notifyUser: send custom mail via %s: %v", host, err)
		return false
	}
	return true
}

// ---------- 触发阶梯分级通知 ----------

// userEmails 返回通知渠道里的邮箱列表;为空时回退注册邮箱。
func userEmails(db *sql.DB, uid int64) []string {
	emails, _ := loadChannels(db, uid)
	if len(emails) > 0 {
		return emails
	}
	var email string
	if err := db.QueryRow(`SELECT email FROM users WHERE id = ?`, uid).Scan(&email); err == nil && email != "" {
		return []string{email}
	}
	return nil
}

// userPhones 返回通知渠道里的手机号列表(免费用户无手机,会员功能)。
func userPhones(db *sql.DB, uid int64) []string {
	_, phones := loadChannels(db, uid)
	return phones
}

// notifyEscalation 按已跨过的档位分级通知(阶梯 4 档):
// 档1(>=d1,<d2)系统通知;档2(>=d2,<d3)+邮件;档3(>=d3,<d4)+短信;
// 档4(>=d4)触发继承由调用方(processEscalation)处理。
// 每天一条:dedup key 带日期,当天重复扫描不重发。
func notifyEscalation(db *sql.DB, uid int64, tier string, daysSince int, ladder []int) {
	if len(ladder) != 4 {
		return
	}
	title := "长时间未登录提醒"
	body := fmt.Sprintf("您已 %d 天未登录,资产安全提醒升级。", daysSince)
	// 系统通知当天已插入则跳过邮件/短信(防刷屏)。
	if !insertReminder(db, uid, "escalation", nil, title, body,
		fmt.Sprintf("esc:%d:%s", uid, time.Now().Format("2006-01-02"))) {
		return
	}
	if daysSince < ladder[1] {
		return // 未到邮件档
	}
	for _, to := range userEmails(db, uid) {
		if quotaAllowed(db, uid, tier, "email") {
			sendMail(to, title, body)
			quotaIncr(db, uid, "email")
		} else {
			log.Printf("notifyEscalation: email quota exceeded for user %d", uid)
		}
	}
	if daysSince < ladder[2] {
		return // 未到短信档
	}
	if tier == "member" {
		for _, phone := range userPhones(db, uid) {
			if quotaAllowed(db, uid, tier, "sms") {
				sendSMS(db, phone, body)
				quotaIncr(db, uid, "sms")
			} else {
				log.Printf("notifyEscalation: sms quota exceeded for user %d", uid)
			}
		}
	}
}