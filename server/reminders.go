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
	TitleTemplate string `json:"title_template"`
	BodyTemplate  string `json:"body_template"`
	IsPreset      int    `json:"is_preset"`
	CreatedAt     string `json:"created_at"`
}

type templateRequest struct {
	Name          string `json:"name"`
	TitleTemplate string `json:"title_template"`
	BodyTemplate  string `json:"body_template"`
}

func validateTemplate(req templateRequest) string {
	if strings.TrimSpace(req.Name) == "" || strings.TrimSpace(req.TitleTemplate) == "" || strings.TrimSpace(req.BodyTemplate) == "" {
		return "name, title_template and body_template are required"
	}
	return ""
}

// handleListTemplates: GET /api/v1/reminder-templates -> 200 system presets + user's own
func handleListTemplates(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT id, name, title_template, body_template, is_preset, created_at
			FROM reminder_templates WHERE user_id IS NULL OR user_id = ? ORDER BY id`, userID(r))
		if err != nil {
			log.Printf("list templates: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		list := []templateJSON{}
		for rows.Next() {
			var t templateJSON
			if err := rows.Scan(&t.ID, &t.Name, &t.TitleTemplate, &t.BodyTemplate, &t.IsPreset, &t.CreatedAt); err != nil {
				log.Printf("scan template: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			list = append(list, t)
		}
		writeJSON(w, http.StatusOK, list)
	}
}

// handleCreateTemplate: POST /api/v1/reminder-templates -> 201; 400 empty fields
func handleCreateTemplate(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req templateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		if msg := validateTemplate(req); msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		res, err := db.Exec(`INSERT INTO reminder_templates (user_id, name, title_template, body_template) VALUES (?, ?, ?, ?)`,
			userID(r), strings.TrimSpace(req.Name), strings.TrimSpace(req.TitleTemplate), strings.TrimSpace(req.BodyTemplate))
		if err != nil {
			log.Printf("insert template: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		id, _ := res.LastInsertId()
		var t templateJSON
		if err := db.QueryRow(`SELECT id, name, title_template, body_template, is_preset, created_at
			FROM reminder_templates WHERE id = ?`, id).
			Scan(&t.ID, &t.Name, &t.TitleTemplate, &t.BodyTemplate, &t.IsPreset, &t.CreatedAt); err != nil {
			log.Printf("fetch created template: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusCreated, t)
	}
}

// handleUpdateTemplate: PUT /api/v1/reminder-templates/{id} -> 200;
// 404 not owned or system (user_id IS NULL); 400 if is_preset (user rows
// created via POST are editable — only system rows with user_id NULL are
// protected, and system rows are already rejected above as not owned).
func handleUpdateTemplate(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		uid := userID(r)
		var owner sql.NullInt64
		var isPreset int
		err = db.QueryRow(`SELECT user_id, is_preset FROM reminder_templates WHERE id = ?`, id).
			Scan(&owner, &isPreset)
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, "template not found")
			return
		}
		if err != nil {
			log.Printf("query template: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if !owner.Valid || owner.Int64 != uid {
			writeError(w, http.StatusNotFound, "template not found")
			return
		}
		if isPreset == 1 {
			writeError(w, http.StatusBadRequest, "preset template is not editable")
			return
		}
		var req templateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		if msg := validateTemplate(req); msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		if _, err := db.Exec(`UPDATE reminder_templates SET name = ?, title_template = ?, body_template = ? WHERE id = ? AND user_id = ?`,
			strings.TrimSpace(req.Name), strings.TrimSpace(req.TitleTemplate), strings.TrimSpace(req.BodyTemplate), id, uid); err != nil {
			log.Printf("update template: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		var t templateJSON
		if err := db.QueryRow(`SELECT id, name, title_template, body_template, is_preset, created_at
			FROM reminder_templates WHERE id = ?`, id).
			Scan(&t.ID, &t.Name, &t.TitleTemplate, &t.BodyTemplate, &t.IsPreset, &t.CreatedAt); err != nil {
			log.Printf("fetch updated template: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
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
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		res, err := db.Exec(`DELETE FROM reminder_templates WHERE id = ? AND user_id = ?`, id, userID(r))
		if err != nil {
			log.Printf("delete template: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "template not found")
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
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		list := []reminderJSON{}
		for rows.Next() {
			var rem reminderJSON
			if err := rows.Scan(&rem.ID, &rem.Type, &rem.Title, &rem.Body, &rem.Status, &rem.CreatedAt); err != nil {
				log.Printf("scan reminder: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
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
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		res, err := db.Exec(`UPDATE reminders SET status = 'read' WHERE id = ? AND user_id = ?`, id, userID(r))
		if err != nil {
			log.Printf("mark reminder read: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "reminder not found")
			return
		}
		w.WriteHeader(http.StatusOK)
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
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		list := []auditJSON{}
		for rows.Next() {
			var a auditJSON
			var detail sql.NullString
			if err := rows.Scan(&a.ID, &a.Actor, &a.Action, &detail, &a.CreatedAt); err != nil {
				log.Printf("scan audit: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
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
