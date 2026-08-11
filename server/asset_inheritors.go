package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strconv"
)

// assetInheritorJSON is one asset↔inheritor binding with trigger rule.
type assetInheritorJSON struct {
	ID          int64  `json:"id"`
	AssetID     int64  `json:"asset_id"`
	InheritorID int64  `json:"inheritor_id"`
	InheritorName string `json:"inheritor_name"`
	Priority    int    `json:"priority"`
	TriggerDays *int   `json:"trigger_days"`
}

type assetInheritorRequest struct {
	InheritorID int64 `json:"inheritor_id"`
	Priority    int   `json:"priority"`
	TriggerDays *int  `json:"trigger_days"`
}

// handleListAssetInheritors: GET /api/v1/assets/{id}/inheritors
func handleListAssetInheritors(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		assetID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		uid := userID(r)
		if !assetOwnedBy(db, assetID, uid) {
			writeError(w, http.StatusNotFound, "asset not found")
			return
		}
		rows, err := db.Query(`SELECT ai.id, ai.asset_id, ai.inheritor_id, i.name,
				ai.priority, ai.trigger_days
			FROM asset_inheritors ai JOIN inheritors i ON i.id = ai.inheritor_id
			WHERE ai.asset_id = ? ORDER BY ai.priority, ai.id`, assetID)
		if err != nil {
			log.Printf("list asset inheritors: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		list := []assetInheritorJSON{}
		for rows.Next() {
			var a assetInheritorJSON
			var td sql.NullInt64
			if err := rows.Scan(&a.ID, &a.AssetID, &a.InheritorID, &a.InheritorName, &a.Priority, &td); err != nil {
				log.Printf("scan asset inheritor: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			if td.Valid {
				n := int(td.Int64)
				a.TriggerDays = &n
			}
			list = append(list, a)
		}
		writeJSON(w, http.StatusOK, list)
	}
}

// handleCreateAssetInheritor: POST /api/v1/assets/{id}/inheritors
func handleCreateAssetInheritor(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		assetID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		uid := userID(r)
		if !assetOwnedBy(db, assetID, uid) {
			writeError(w, http.StatusNotFound, "asset not found")
			return
		}
		var req assetInheritorRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		// inheritor must belong to the same user.
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM inheritors WHERE id = ? AND user_id = ?`,
			req.InheritorID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusBadRequest, "invalid inheritor")
			return
		}
		priority := req.Priority
		if priority < 1 {
			priority = 1
		}
		res, err := db.Exec(`INSERT INTO asset_inheritors (asset_id, inheritor_id, priority, trigger_days)
			VALUES (?, ?, ?, ?)`,
			assetID, req.InheritorID, priority, nullableInt(req.TriggerDays))
		if err != nil {
			// UNIQUE(asset_id, inheritor_id) 冲突 = 已绑定。
			log.Printf("insert asset inheritor: %v", err)
			writeError(w, http.StatusBadRequest, "inheritor already bound to asset")
			return
		}
		id, _ := res.LastInsertId()
		writeJSON(w, http.StatusCreated, map[string]any{"id": id})
	}
}

// handleDeleteAssetInheritor: DELETE /api/v1/assets/{id}/inheritors/{iid}
func handleDeleteAssetInheritor(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		assetID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		uid := userID(r)
		if !assetOwnedBy(db, assetID, uid) {
			writeError(w, http.StatusNotFound, "asset not found")
			return
		}
		iidStr := r.PathValue("iid")
		iid, err := strconv.ParseInt(iidStr, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid inheritor id")
			return
		}
		res, err := db.Exec(`DELETE FROM asset_inheritors WHERE asset_id = ? AND id = ?`, assetID, iid)
		if err != nil {
			log.Printf("delete asset inheritor: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "binding not found")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

// assetOwnedBy reports whether the asset belongs to uid.
func assetOwnedBy(db *sql.DB, assetID, uid int64) bool {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM assets WHERE id = ? AND user_id = ?`,
		assetID, uid).Scan(&n); err == nil {
		return n > 0
	}
	return false
}

func nullableInt(p *int) any {
	if p == nil {
		return nil
	}
	return *p
}

// ---------- category (group) inheritors ----------

type categoryInheritorJSON struct {
	ID             int64  `json:"id"`
	CategoryID     int64  `json:"category_id"`
	InheritorID    int64  `json:"inheritor_id"`
	InheritorName  string `json:"inheritor_name"`
	Priority       int    `json:"priority"`
	TriggerDays    *int   `json:"trigger_days"`
}

// handleListCategoryInheritors: GET /api/v1/categories/{id}/inheritors
func handleListCategoryInheritors(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		catID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		uid := userID(r)
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM categories WHERE id = ? AND user_id = ?`,
			catID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusNotFound, "category not found")
			return
		}
		rows, err := db.Query(`SELECT ci.id, ci.category_id, ci.inheritor_id, i.name,
				ci.priority, ci.trigger_days
			FROM category_inheritors ci JOIN inheritors i ON i.id = ci.inheritor_id
			WHERE ci.category_id = ? ORDER BY ci.priority, ci.id`, catID)
		if err != nil {
			log.Printf("list category inheritors: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		list := []categoryInheritorJSON{}
		for rows.Next() {
			var a categoryInheritorJSON
			var td sql.NullInt64
			if err := rows.Scan(&a.ID, &a.CategoryID, &a.InheritorID, &a.InheritorName, &a.Priority, &td); err != nil {
				log.Printf("scan category inheritor: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			if td.Valid {
				n := int(td.Int64)
				a.TriggerDays = &n
			}
			list = append(list, a)
		}
		writeJSON(w, http.StatusOK, list)
	}
}

// handleCreateCategoryInheritor: POST /api/v1/categories/{id}/inheritors
func handleCreateCategoryInheritor(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		catID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		uid := userID(r)
		var req assetInheritorRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM categories WHERE id = ? AND user_id = ?`,
			catID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusNotFound, "category not found")
			return
		}
		if err := db.QueryRow(`SELECT COUNT(*) FROM inheritors WHERE id = ? AND user_id = ?`,
			req.InheritorID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusBadRequest, "invalid inheritor")
			return
		}
		priority := req.Priority
		if priority < 1 {
			priority = 1
		}
		res, err := db.Exec(`INSERT INTO category_inheritors (category_id, inheritor_id, priority, trigger_days)
			VALUES (?, ?, ?, ?)`,
			catID, req.InheritorID, priority, nullableInt(req.TriggerDays))
		if err != nil {
			log.Printf("insert category inheritor: %v", err)
			writeError(w, http.StatusBadRequest, "inheritor already bound to group")
			return
		}
		id, _ := res.LastInsertId()
		writeJSON(w, http.StatusCreated, map[string]any{"id": id})
	}
}

// handleDeleteCategoryInheritor: DELETE /api/v1/categories/{id}/inheritors/{iid}
func handleDeleteCategoryInheritor(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		catID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		uid := userID(r)
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM categories WHERE id = ? AND user_id = ?`,
			catID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusNotFound, "category not found")
			return
		}
		iidStr := r.PathValue("iid")
		iid, err := strconv.ParseInt(iidStr, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid inheritor id")
			return
		}
		res, err := db.Exec(`DELETE FROM category_inheritors WHERE category_id = ? AND id = ?`, catID, iid)
		if err != nil {
			log.Printf("delete category inheritor: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "binding not found")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

// inheritorAssetJSON: 继承人在某个资产上的绑定信息(来源:直接绑定或分组继承)。
type inheritorAssetJSON struct {
	BindingID    int64  `json:"binding_id"`
	BindingType  string `json:"binding_type"` // 'asset' | 'category'
	AssetID      int64  `json:"asset_id"`
	AssetName    string `json:"asset_name"`
	CategoryName string `json:"category_name"`
	TriggerDays  *int   `json:"trigger_days"`
}

// handleListInheritorAssets: GET /api/v1/inheritors/{id}/assets ->
// 该继承人绑定的所有资产(资产级直接绑定 + 经分组绑定),含 binding_id 供解绑。
func handleListInheritorAssets(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		inIDStr := r.PathValue("id")
		inID, err := strconv.ParseInt(inIDStr, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid inheritor id")
			return
		}
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM inheritors WHERE id = ? AND user_id = ?`,
			inID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusNotFound, "inheritor not found")
			return
		}
		rows, err := db.Query(`SELECT 'asset' AS bt, ai.id, ai.asset_id, a.name AS asset_name, c.name, ai.trigger_days
			FROM asset_inheritors ai
			JOIN assets a ON a.id = ai.asset_id AND a.user_id = ?
			LEFT JOIN categories c ON c.id = a.category_id
			WHERE ai.inheritor_id = ?
			UNION ALL
			SELECT 'category' AS bt, ci.id, a.id, a.name AS asset_name, c.name, ci.trigger_days
			FROM category_inheritors ci
			JOIN categories c ON c.id = ci.category_id
			JOIN assets a ON a.category_id = c.id AND a.user_id = ?
			WHERE ci.inheritor_id = ?
				AND NOT EXISTS (SELECT 1 FROM asset_inheritors ai2 WHERE ai2.asset_id = a.id)
			ORDER BY bt, asset_name`, uid, inID, uid, inID)
		if err != nil {
			log.Printf("list inheritor assets: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		list := []inheritorAssetJSON{}
		for rows.Next() {
			var a inheritorAssetJSON
			var catName sql.NullString
			var td sql.NullInt64
			if err := rows.Scan(&a.BindingType, &a.BindingID, &a.AssetID, &a.AssetName, &catName, &td); err != nil {
				log.Printf("scan inheritor asset: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			if catName.Valid {
				a.CategoryName = catName.String
			}
			if td.Valid {
				n := int(td.Int64)
				a.TriggerDays = &n
			}
			list = append(list, a)
		}
		writeJSON(w, http.StatusOK, list)
	}
}
