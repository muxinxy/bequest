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
	AssetType string `json:"asset_type"`
	IsPreset  int    `json:"is_preset"`
	CreatedAt string `json:"created_at"`
}

// validAssetType reports whether s is a supported category type.
func validAssetType(s string) bool {
	return s == "physical" || s == "virtual"
}

// handleListCategories: GET /api/v1/categories -> 200 []
func handleListCategories(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT id, name, asset_type, is_preset, created_at FROM categories WHERE user_id = ? ORDER BY id`, userID(r))
		if err != nil {
			log.Printf("list categories: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		cats := []categoryJSON{}
		for rows.Next() {
			var c categoryJSON
			if err := rows.Scan(&c.ID, &c.Name, &c.AssetType, &c.IsPreset, &c.CreatedAt); err != nil {
				log.Printf("scan category: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			cats = append(cats, c)
		}
		writeJSON(w, http.StatusOK, cats)
	}
}

// handleCreateCategory: POST /api/v1/categories -> 201; 400 empty name / bad
// asset_type; 409 duplicate
func handleCreateCategory(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Name      string `json:"name"`
			AssetType string `json:"asset_type"`
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
		assetType := req.AssetType
		if assetType == "" {
			assetType = "physical"
		}
		if !validAssetType(assetType) {
			writeError(w, http.StatusBadRequest, "asset_type must be physical or virtual")
			return
		}
		res, err := db.Exec(`INSERT INTO categories (user_id, name, asset_type, is_preset) VALUES (?, ?, ?, 0)`, userID(r), name, assetType)
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
		if err := db.QueryRow(`SELECT name, asset_type, is_preset, created_at FROM categories WHERE id = ?`, id).
			Scan(&c.Name, &c.AssetType, &c.IsPreset, &c.CreatedAt); err != nil {
			log.Printf("fetch created category: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		c.ID = id
		writeJSON(w, http.StatusCreated, c)
	}
}

// handleUpdateCategory: PUT /api/v1/categories/{id} -> 200; 400 empty name /
// bad asset_type; 409 duplicate (excluding self); 404 not owned. Renaming or
// retargeting works on preset rows too.
func handleUpdateCategory(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		var req struct {
			Name      string `json:"name"`
			AssetType string `json:"asset_type"`
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
		assetType := req.AssetType
		if assetType == "" {
			assetType = "physical"
		}
		if !validAssetType(assetType) {
			writeError(w, http.StatusBadRequest, "asset_type must be physical or virtual")
			return
		}
		// UNIQUE(user_id,name) is checked against other rows only, so updating
		// a row to its own current name (retarget-only PUT) is not a conflict.
		res, err := db.Exec(`UPDATE categories SET name = ?, asset_type = ? WHERE id = ? AND user_id = ?`,
			name, assetType, id, userID(r))
		if err != nil {
			if isUniqueViolation(err) {
				writeError(w, http.StatusConflict, "category already exists")
				return
			}
			log.Printf("update category: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "category not found")
			return
		}
		var c categoryJSON
		if err := db.QueryRow(`SELECT name, asset_type, is_preset, created_at FROM categories WHERE id = ?`, id).
			Scan(&c.Name, &c.AssetType, &c.IsPreset, &c.CreatedAt); err != nil {
			log.Printf("fetch updated category: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		c.ID = id
		writeJSON(w, http.StatusOK, c)
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
