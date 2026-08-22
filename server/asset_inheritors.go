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
		logAudit(db, userID(r), "绑定资产继承人", map[string]any{"asset_id": assetID, "inheritor_id": req.InheritorID})
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
		logAudit(db, userID(r), "解绑资产继承人", map[string]any{"asset_id": assetID, "binding_id": iid})
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
		logAudit(db, userID(r), "绑定分组继承人", map[string]any{"category_id": catID, "inheritor_id": req.InheritorID})
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
		logAudit(db, userID(r), "解绑分组继承人", map[string]any{"category_id": catID, "binding_id": iid})
		w.WriteHeader(http.StatusNoContent)
	}
}

// handleListCategoryInheritorAssets: GET /api/v1/categories/{id}/inheritors/{iid}/assets
// -> 经该分组绑定继承的资产列表(排除已资产级绑定的资产),供继承预览。
func handleListCategoryInheritorAssets(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		catID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		iidStr := r.PathValue("iid")
		iid, err := strconv.ParseInt(iidStr, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid inheritor id")
			return
		}
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM category_inheritors ci
			JOIN categories c ON c.id = ci.category_id
			WHERE ci.id = ? AND ci.category_id = ? AND c.user_id = ?`, iid, catID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusNotFound, "binding not found")
			return
		}
		rows, err := db.Query(`SELECT a.id, a.name, a.asset_type, a.expiry_date
			FROM assets a
			WHERE a.category_id = ? AND a.user_id = ?
				AND NOT EXISTS (SELECT 1 FROM asset_inheritors ai2 WHERE ai2.asset_id = a.id)
			ORDER BY a.name`, catID, uid)
		if err != nil {
			log.Printf("list category inheritor assets: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		type assetItem struct {
			ID         int64   `json:"id"`
			Name       string  `json:"name"`
			AssetType  string  `json:"asset_type"`
			ExpiryDate *string `json:"expiry_date"`
		}
		list := []assetItem{}
		for rows.Next() {
			var a assetItem
			var exp sql.NullString
			if err := rows.Scan(&a.ID, &a.Name, &a.AssetType, &exp); err != nil {
				log.Printf("scan category inheritor asset: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			if exp.Valid {
				a.ExpiryDate = &exp.String
			}
			list = append(list, a)
		}
		writeJSON(w, http.StatusOK, map[string]any{"assets": list})
	}
}

// inheritorAssetJSON: 继承人的绑定条目(分组绑定或资产级绑定)。
// 分组行为一个实体(含经分组继承的资产数),不再展开成逐资产行——
// 空分组、与资产级绑定并存的场景都能在列表可见、可解绑。
type inheritorAssetJSON struct {
	BindingID    int64  `json:"binding_id"`
	BindingType  string `json:"binding_type"` // 'asset' | 'category'
	AssetID      *int64 `json:"asset_id"`     // 分组行为 null
	AssetName    string `json:"asset_name"`   // 分组行为空
	CategoryID   *int64 `json:"category_id"`
	CategoryName string `json:"category_name"`
	TriggerDays  *int   `json:"trigger_days"`
	AssetCount   int    `json:"asset_count"` // 分组行:经该分组继承的资产数
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
		// 分组绑定:一行一个分组(含经该分组继承的资产数,排除已资产级绑定的资产)。
		rows, err := db.Query(`SELECT 'category' AS bt, ci.id AS binding_id, ci.category_id, NULL AS asset_id, '' AS asset_name, c.name AS category_name, ci.trigger_days,
				(SELECT COUNT(*) FROM assets a
				 WHERE a.category_id = ci.category_id AND a.user_id = ?
				   AND NOT EXISTS (SELECT 1 FROM asset_inheritors ai2 WHERE ai2.asset_id = a.id)) AS asset_count
			FROM category_inheritors ci
			JOIN categories c ON c.id = ci.category_id
			WHERE ci.inheritor_id = ?
			UNION ALL
			SELECT 'asset' AS bt, ai.id AS binding_id, a.category_id, a.id AS asset_id, a.name AS asset_name, COALESCE(c.name, '') AS category_name, ai.trigger_days, 0 AS asset_count
			FROM asset_inheritors ai
			JOIN assets a ON a.id = ai.asset_id AND a.user_id = ?
			LEFT JOIN categories c ON c.id = a.category_id
			WHERE ai.inheritor_id = ?
			ORDER BY bt, category_name, asset_name`, uid, inID, uid, inID)
		if err != nil {
			log.Printf("list inheritor assets: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		list := []inheritorAssetJSON{}
		for rows.Next() {
			var a inheritorAssetJSON
			var assetID, catID, td sql.NullInt64
			var assetName, catName sql.NullString
			var count int
			if err := rows.Scan(&a.BindingType, &a.BindingID, &catID, &assetID, &assetName, &catName, &td, &count); err != nil {
				log.Printf("scan inheritor asset: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			if assetID.Valid {
				n := assetID.Int64
				a.AssetID = &n
			}
			a.AssetName = assetName.String
			if catID.Valid {
				n := catID.Int64
				a.CategoryID = &n
			}
			a.CategoryName = catName.String
			if td.Valid {
				n := int(td.Int64)
				a.TriggerDays = &n
			}
			a.AssetCount = count
			list = append(list, a)
		}
		writeJSON(w, http.StatusOK, list)
	}
}
