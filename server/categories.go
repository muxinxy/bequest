package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
)

// userID returns the authenticated user's id from the request context
// (populated by requireAuth).
func userID(r *http.Request) int64 {
	return r.Context().Value(ctxUserIDKey).(int64)
}

// parseID reads the {id} path wildcard as an int64.
func parseID(r *http.Request) (int64, error) {
	return strconv.ParseInt(r.PathValue("id"), 10, 64)
}

// ---------- categories ----------

type categoryJSON struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	CreatedAt string `json:"created_at"`
}

// handleListCategories: GET /api/v1/categories -> 200 []
func handleListCategories(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT id, name, created_at FROM categories WHERE user_id = ? ORDER BY id`, userID(r))
		if err != nil {
			log.Printf("list categories: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		cats := []categoryJSON{}
		for rows.Next() {
			var c categoryJSON
			if err := rows.Scan(&c.ID, &c.Name, &c.CreatedAt); err != nil {
				log.Printf("scan category: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			cats = append(cats, c)
		}
		writeJSON(w, http.StatusOK, cats)
	}
}

// handleCreateCategory: POST /api/v1/categories -> 201; 400 empty name; 409 duplicate
func handleCreateCategory(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Name string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		name := strings.TrimSpace(req.Name)
		if name == "" {
			writeError(w, http.StatusBadRequest, "name is required")
			return
		}
		res, err := db.Exec(`INSERT INTO categories (user_id, name) VALUES (?, ?)`, userID(r), name)
		if err != nil {
			if isUniqueViolation(err) {
				writeError(w, http.StatusConflict, "category already exists")
				return
			}
			log.Printf("insert category: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		id, _ := res.LastInsertId()
		var c categoryJSON
		if err := db.QueryRow(`SELECT name, created_at FROM categories WHERE id = ?`, id).
			Scan(&c.Name, &c.CreatedAt); err != nil {
			log.Printf("fetch created category: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		c.ID = id
		writeJSON(w, http.StatusCreated, c)
	}
}

// handleDeleteCategory: DELETE /api/v1/categories/{id} -> 204; 404 not owned
func handleDeleteCategory(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		res, err := db.Exec(`DELETE FROM categories WHERE id = ? AND user_id = ?`, id, userID(r))
		if err != nil {
			log.Printf("delete category: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "category not found")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}
