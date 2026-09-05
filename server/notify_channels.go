package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strings"
)

// ---------- 通知渠道(邮箱/手机号/IM webhook) ----------

type channelsRequest struct {
	Emails   []string `json:"emails"`
	Phones   []string `json:"phones"`
	Wecom    []string `json:"wecom"`
	Dingtalk []string `json:"dingtalk"`
	Feishu   []string `json:"feishu"`
}

// channelSet 是一次读出的全部渠道列表。
type channelSet struct {
	emails, phones, wecom, dingtalk, feishu []string
}

// loadChannels 读取该用户的全部渠道列表(按 sort_order)。
func loadChannels(db *sql.DB, uid int64) channelSet {
	var ch channelSet
	rows, err := db.Query(`SELECT type, value FROM notification_channels
		WHERE user_id = ? ORDER BY sort_order, id`, uid)
	if err != nil {
		log.Printf("load channels: %v", err)
		return ch
	}
	defer rows.Close()
	for rows.Next() {
		var typ, val string
		if err := rows.Scan(&typ, &val); err != nil {
			log.Printf("scan channel: %v", err)
			return ch
		}
		switch typ {
		case "email":
			ch.emails = append(ch.emails, val)
		case "phone":
			ch.phones = append(ch.phones, val)
		case "wecom":
			ch.wecom = append(ch.wecom, val)
		case "dingtalk":
			ch.dingtalk = append(ch.dingtalk, val)
		case "feishu":
			ch.feishu = append(ch.feishu, val)
		}
	}
	return ch
}

// validateChannels:邮箱/手机号/IM 各 0-3 个;IM 校验 webhook URL 域名与 https。
func validateChannels(req channelsRequest) string {
	if len(req.Emails) > 3 {
		return "邮箱最多 3 个"
	}
	if len(req.Phones) > 3 {
		return "手机号最多 3 个"
	}
	for _, e := range req.Emails {
		if !strings.Contains(strings.TrimSpace(e), "@") {
			return "邮箱格式不正确"
		}
	}
	for _, p := range req.Phones {
		if !isPhone(strings.TrimSpace(p)) {
			return "手机号格式不正确"
		}
	}
	if msg := validateIMURLs("企业微信", "qyapi.weixin.qq.com", req.Wecom); msg != "" {
		return msg
	}
	if msg := validateIMURLs("钉钉", "oapi.dingtalk.com", req.Dingtalk); msg != "" {
		return msg
	}
	if msg := validateIMURLs("飞书", "open.feishu.cn", req.Feishu); msg != "" {
		return msg
	}
	return ""
}

// validateIMURLs:每个 webhook 以 https:// 开头且包含平台域名(飞书额外接受 larksuite)。
func validateIMURLs(name, domain string, urls []string) string {
	if len(urls) > 3 {
		return name + "最多 3 个"
	}
	for _, u := range urls {
		u = strings.TrimSpace(u)
		if !strings.HasPrefix(u, "https://") {
			return name + "webhook 必须以 https:// 开头"
		}
		if !strings.Contains(u, domain) && !(name == "飞书" && strings.Contains(u, "open.larksuite.com")) {
			return name + "webhook 域名不正确"
		}
	}
	return ""
}

// isPhone:5-20 位纯数字(放宽版,覆盖 1 开头 11 位)。
func isPhone(p string) bool {
	if len(p) < 5 || len(p) > 20 {
		return false
	}
	for _, c := range p {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// handleGetNotificationChannels: GET /api/v1/notification-channels -> 200 {emails,phones,wecom,dingtalk,feishu}
func handleGetNotificationChannels(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ch := loadChannels(db, userID(r))
		writeJSON(w, http.StatusOK, map[string][]string{
			"emails": ch.emails, "phones": ch.phones,
			"wecom": ch.wecom, "dingtalk": ch.dingtalk, "feishu": ch.feishu,
		})
	}
}

// handlePutNotificationChannels: PUT /api/v1/notification-channels {emails,phones,wecom,dingtalk,feishu} -> 200
// 整体替换;免费用户提交手机号 -> 400;IM 不限 tier。
func handlePutNotificationChannels(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req channelsRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if msg := validateChannels(req); msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		if len(req.Phones) > 0 {
			var tier string
			if err := db.QueryRow(`SELECT tier FROM users WHERE id = ?`, uid).Scan(&tier); err != nil {
				log.Printf("query tier: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if tier != "member" {
				writeError(w, http.StatusBadRequest, "手机号功能为会员专属")
				return
			}
		}
		tx, err := db.Begin()
		if err != nil {
			log.Printf("begin channels tx: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if _, err := tx.Exec(`DELETE FROM notification_channels WHERE user_id = ?`, uid); err != nil {
			tx.Rollback()
			log.Printf("clear channels: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		for i, e := range req.Emails {
			if _, err := tx.Exec(`INSERT INTO notification_channels (user_id, type, value, sort_order) VALUES (?, 'email', ?, ?)`,
				uid, strings.TrimSpace(e), i); err != nil {
				tx.Rollback()
				log.Printf("insert email channel: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
		}
		for i, p := range req.Phones {
			if _, err := tx.Exec(`INSERT INTO notification_channels (user_id, type, value, sort_order) VALUES (?, 'phone', ?, ?)`,
				uid, strings.TrimSpace(p), i); err != nil {
				tx.Rollback()
				log.Printf("insert phone channel: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
		}
		for _, im := range []struct {
			typ  string
			urls []string
		}{{"wecom", req.Wecom}, {"dingtalk", req.Dingtalk}, {"feishu", req.Feishu}} {
			for i, u := range im.urls {
				if _, err := tx.Exec(`INSERT INTO notification_channels (user_id, type, value, sort_order) VALUES (?, ?, ?, ?)`,
					uid, im.typ, strings.TrimSpace(u), i); err != nil {
					tx.Rollback()
					log.Printf("insert im channel: %v", err)
					writeError(w, http.StatusInternalServerError, "服务器内部错误")
					return
				}
			}
		}
		if err := tx.Commit(); err != nil {
			log.Printf("commit channels: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}
