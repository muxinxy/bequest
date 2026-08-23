package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strings"
)

// ---------- 通知渠道(邮箱/手机号) ----------

type channelsRequest struct {
	Emails []string `json:"emails"`
	Phones []string `json:"phones"`
}

// loadChannels 读取该用户的邮箱/手机号列表(按 sort_order)。
func loadChannels(db *sql.DB, uid int64) (emails, phones []string) {
	rows, err := db.Query(`SELECT type, value FROM notification_channels
		WHERE user_id = ? ORDER BY sort_order, id`, uid)
	if err != nil {
		log.Printf("load channels: %v", err)
		return
	}
	defer rows.Close()
	for rows.Next() {
		var typ, val string
		if err := rows.Scan(&typ, &val); err != nil {
			log.Printf("scan channel: %v", err)
			return
		}
		if typ == "email" {
			emails = append(emails, val)
		} else {
			phones = append(phones, val)
		}
	}
	return
}

// validateChannels:邮箱/手机号各 0-3 个,格式简单校验。
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

// handleGetNotificationChannels: GET /api/v1/notification-channels -> 200 {emails,phones}
func handleGetNotificationChannels(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		emails, phones := loadChannels(db, userID(r))
		writeJSON(w, http.StatusOK, map[string][]string{"emails": emails, "phones": phones})
	}
}

// handlePutNotificationChannels: PUT /api/v1/notification-channels {emails,phones} -> 200
// 整体替换;免费用户提交手机号 -> 400。
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
		if err := tx.Commit(); err != nil {
			log.Printf("commit channels: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}