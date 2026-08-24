package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
)

// ---------- reminder templates ----------

type templateJSON struct {
	ID            int64  `json:"id"`
	Name          string `json:"name"`
	Type          string `json:"type"`
	TitleTemplate string `json:"title_template"`
	BodyTemplate  string `json:"body_template"`
	IsPreset      int    `json:"is_preset"`
	CreatedAt     string `json:"created_at"`
}

type templateRequest struct {
	Name          string `json:"name"`
	Type          string `json:"type"`
	TitleTemplate string `json:"title_template"`
	BodyTemplate  string `json:"body_template"`
}

// validTemplateType 校验模板类型;空则默认 expiry。
func validTemplateType(t string) string {
	switch t {
	case "", "expiry":
		return "expiry"
	case "escalation", "inheritance":
		return t
	}
	return ""
}

func validateTemplate(req templateRequest) string {
	if strings.TrimSpace(req.Name) == "" || strings.TrimSpace(req.TitleTemplate) == "" || strings.TrimSpace(req.BodyTemplate) == "" {
		return "名称、标题模板和正文模板均必填"
	}
	return ""
}

// handleListTemplates: GET /api/v1/reminder-templates -> 200 system presets + user's own
func handleListTemplates(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT id, name, type, title_template, body_template, is_preset, created_at
			FROM reminder_templates WHERE user_id IS NULL OR user_id = ? ORDER BY id`, userID(r))
		if err != nil {
			log.Printf("list templates: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		list := []templateJSON{}
		for rows.Next() {
			var t templateJSON
			if err := rows.Scan(&t.ID, &t.Name, &t.Type, &t.TitleTemplate, &t.BodyTemplate, &t.IsPreset, &t.CreatedAt); err != nil {
				log.Printf("scan template: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			list = append(list, t)
		}
		writeJSON(w, http.StatusOK, list)
	}
}

// handleCreateTemplate: POST /api/v1/reminder-templates -> 201; 400 empty fields
// 免费用户不可创建自定义模板(预设模板已可用);type 校验合法性。
func handleCreateTemplate(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req templateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if msg := validateTemplate(req); msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		uid := userID(r)
		var tier string
		if err := db.QueryRow(`SELECT tier FROM users WHERE id = ?`, uid).Scan(&tier); err != nil {
			log.Printf("query tier: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if tier != "member" {
			writeError(w, http.StatusBadRequest, "自定义提醒模板为会员功能")
			return
		}
		typ := validTemplateType(req.Type)
		if typ == "" {
			writeError(w, http.StatusBadRequest, "模板类型不合法")
			return
		}
		res, err := db.Exec(`INSERT INTO reminder_templates (user_id, name, type, title_template, body_template) VALUES (?, ?, ?, ?, ?)`,
			uid, strings.TrimSpace(req.Name), typ, strings.TrimSpace(req.TitleTemplate), strings.TrimSpace(req.BodyTemplate))
		if err != nil {
			log.Printf("insert template: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		id, _ := res.LastInsertId()
		var t templateJSON
		if err := db.QueryRow(`SELECT id, name, type, title_template, body_template, is_preset, created_at
			FROM reminder_templates WHERE id = ?`, id).
			Scan(&t.ID, &t.Name, &t.Type, &t.TitleTemplate, &t.BodyTemplate, &t.IsPreset, &t.CreatedAt); err != nil {
			log.Printf("fetch created template: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusCreated, t)
	}
}

// handleUpdateTemplate: PUT /api/v1/reminder-templates/{id} -> 200;
// 本人模板可改;系统预设(user_id IS NULL)仅管理员可改,普通用户 404。
func handleUpdateTemplate(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		var owner sql.NullInt64
		err = db.QueryRow(`SELECT user_id FROM reminder_templates WHERE id = ?`, id).
			Scan(&owner)
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, "提醒模板不存在")
			return
		}
		if err != nil {
			log.Printf("query template: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if !owner.Valid {
			// 系统预设:仅管理员可编辑。
			var role string
			if err := db.QueryRow(`SELECT role FROM users WHERE id = ?`, uid).Scan(&role); err != nil || role != "admin" {
				writeError(w, http.StatusNotFound, "提醒模板不存在")
				return
			}
		} else if owner.Int64 != uid {
			writeError(w, http.StatusNotFound, "提醒模板不存在")
			return
		}
		var req templateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if msg := validateTemplate(req); msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		typ := validTemplateType(req.Type)
		if typ == "" {
			writeError(w, http.StatusBadRequest, "模板类型不合法")
			return
		}
		if _, err := db.Exec(`UPDATE reminder_templates SET name = ?, type = ?, title_template = ?, body_template = ? WHERE id = ?`,
			strings.TrimSpace(req.Name), typ, strings.TrimSpace(req.TitleTemplate), strings.TrimSpace(req.BodyTemplate), id); err != nil {
			log.Printf("update template: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		var t templateJSON
		if err := db.QueryRow(`SELECT id, name, type, title_template, body_template, is_preset, created_at
			FROM reminder_templates WHERE id = ?`, id).
			Scan(&t.ID, &t.Name, &t.Type, &t.TitleTemplate, &t.BodyTemplate, &t.IsPreset, &t.CreatedAt); err != nil {
			log.Printf("fetch updated template: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusOK, t)
	}
}

// handleDeleteTemplate: DELETE /api/v1/reminder-templates/{id} -> 204;
// 404 not owned (system rows have user_id NULL and never match).
func handleDeleteTemplate(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		res, err := db.Exec(`DELETE FROM reminder_templates WHERE id = ? AND user_id = ?`, id, userID(r))
		if err != nil {
			log.Printf("delete template: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "提醒模板不存在")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

// ---------- reminders ----------

type reminderJSON struct {
	ID        int64  `json:"id"`
	Type      string `json:"type"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	Status    string `json:"status"`
	CreatedAt string `json:"created_at"`
}

// handleListReminders: GET /api/v1/reminders -> 200 newest first, max 100
func handleListReminders(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT id, type, title, body, status, created_at
			FROM reminders WHERE user_id = ? ORDER BY id DESC LIMIT 100`, userID(r))
		if err != nil {
			log.Printf("list reminders: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		list := []reminderJSON{}
		for rows.Next() {
			var rem reminderJSON
			if err := rows.Scan(&rem.ID, &rem.Type, &rem.Title, &rem.Body, &rem.Status, &rem.CreatedAt); err != nil {
				log.Printf("scan reminder: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			list = append(list, rem)
		}
		writeJSON(w, http.StatusOK, list)
	}
}

// handleMarkReminderRead: POST /api/v1/reminders/{id}/read -> 200 (idempotent); 404 not owned
func handleMarkReminderRead(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		res, err := db.Exec(`UPDATE reminders SET status = 'read' WHERE id = ? AND user_id = ?`, id, userID(r))
		if err != nil {
			log.Printf("mark reminder read: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "提醒不存在")
			return
		}
		w.WriteHeader(http.StatusOK)
	}
}

// handleMarkAllRemindersRead: POST /api/v1/reminders/read-all -> 200 {"marked":n}
// 将该用户全部未读提醒标记为已读。
func handleMarkAllRemindersRead(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		res, err := db.Exec(`UPDATE reminders SET status = 'read'
			WHERE user_id = ? AND status = 'pending'`, userID(r))
		if err != nil {
			log.Printf("mark all reminders read: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		n, _ := res.RowsAffected()
		writeJSON(w, http.StatusOK, map[string]int64{"marked": n})
	}
}

// ---------- audit log ----------

type auditJSON struct {
	ID        int64   `json:"id"`
	Actor     string  `json:"actor"`
	Action    string  `json:"action"`
	Detail    *string `json:"detail"`
	CreatedAt string  `json:"created_at"`
}

// handleAuditLog: GET /api/v1/audit-log -> 200 newest first, max 200
func handleAuditLog(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT id, actor, action, detail, created_at
			FROM audit_logs WHERE user_id = ? ORDER BY id DESC LIMIT 200`, userID(r))
		if err != nil {
			log.Printf("list audit: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		list := []auditJSON{}
		for rows.Next() {
			var a auditJSON
			var detail sql.NullString
			if err := rows.Scan(&a.ID, &a.Actor, &a.Action, &detail, &a.CreatedAt); err != nil {
				log.Printf("scan audit: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if detail.Valid {
				a.Detail = &detail.String
			}
			list = append(list, a)
		}
		writeJSON(w, http.StatusOK, list)
	}
}
