package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
)

// assetInheritorJSON is one asset↔inheritor binding with trigger rule.
type assetInheritorJSON struct {
	ID            int64  `json:"id"`
	AssetID       int64  `json:"asset_id"`
	InheritorID   int64  `json:"inheritor_id"`
	InheritorName string `json:"inheritor_name"`
	Priority      int    `json:"priority"`
	TriggerDays   *int   `json:"trigger_days"`
	LadderID      *int64 `json:"ladder_id"`   // NULL=全局阶梯
	LadderName    string `json:"ladder_name"` // 空=全局阶梯
}

type assetInheritorRequest struct {
	InheritorID int64  `json:"inheritor_id"`
	Priority    int    `json:"priority"`
	TriggerDays *int   `json:"trigger_days"`
	LadderID    *int64 `json:"ladder_id"`
}

// handleListAssetInheritors: GET /api/v1/assets/{id}/inheritors
func handleListAssetInheritors(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		assetID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		if !assetOwnedBy(db, assetID, uid) {
			writeError(w, http.StatusNotFound, "资产不存在")
			return
		}
		rows, err := db.Query(`SELECT ai.id, ai.asset_id, ai.inheritor_id, i.name,
				ai.priority, ai.trigger_days, ai.ladder_id, COALESCE(tl.name, '')
			FROM asset_inheritors ai JOIN inheritors i ON i.id = ai.inheritor_id
			LEFT JOIN trigger_ladders tl ON tl.id = ai.ladder_id
			WHERE ai.asset_id = ? ORDER BY ai.priority, ai.id`, assetID)
		if err != nil {
			log.Printf("list asset inheritors: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		list := []assetInheritorJSON{}
		for rows.Next() {
			var a assetInheritorJSON
			var td sql.NullInt64
			var lid sql.NullInt64
			if err := rows.Scan(&a.ID, &a.AssetID, &a.InheritorID, &a.InheritorName, &a.Priority, &td, &lid, &a.LadderName); err != nil {
				log.Printf("scan asset inheritor: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if td.Valid {
				n := int(td.Int64)
				a.TriggerDays = &n
			}
			if lid.Valid {
				n := lid.Int64
				a.LadderID = &n
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
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		if !assetOwnedBy(db, assetID, uid) {
			writeError(w, http.StatusNotFound, "资产不存在")
			return
		}
		var req assetInheritorRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		// inheritor must belong to the same user.
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM inheritors WHERE id = ? AND user_id = ?`,
			req.InheritorID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusBadRequest, "无效的继承人")
			return
		}
		if req.LadderID != nil && !ladderOwnedBy(db, *req.LadderID, uid) {
			writeError(w, http.StatusBadRequest, "无效的触发阶梯")
			return
		}
		priority := req.Priority
		if priority < 1 {
			priority = 1
		}
		res, err := db.Exec(`INSERT INTO asset_inheritors (asset_id, inheritor_id, priority, trigger_days, ladder_id)
			VALUES (?, ?, ?, ?, ?)`,
			assetID, req.InheritorID, priority, nullableInt(req.TriggerDays), nullableLadderID(req.LadderID))
		if err != nil {
			// UNIQUE(asset_id, inheritor_id) 冲突 = 已绑定。
			log.Printf("insert asset inheritor: %v", err)
			writeError(w, http.StatusBadRequest, "该继承人已绑定此资产")
			return
		}
		id, _ := res.LastInsertId()
		var assetName, inName string
		if err := db.QueryRow(`SELECT a.name, i.name FROM assets a JOIN inheritors i ON i.id = ?
			WHERE a.id = ? AND a.user_id = ? AND i.user_id = ?`,
			req.InheritorID, assetID, uid, uid).Scan(&assetName, &inName); err != nil {
			log.Printf("query bind names: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		logAudit(db, userID(r), fmt.Sprintf("将继承人「%s」绑定为资产「%s」的继承人", inName, assetName), map[string]any{"asset_id": assetID, "inheritor_id": req.InheritorID})
		writeJSON(w, http.StatusCreated, map[string]any{"id": id})
	}
}

// handleDeleteAssetInheritor: DELETE /api/v1/assets/{id}/inheritors/{iid}
func handleDeleteAssetInheritor(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		assetID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		if !assetOwnedBy(db, assetID, uid) {
			writeError(w, http.StatusNotFound, "资产不存在")
			return
		}
		iidStr := r.PathValue("iid")
		iid, err := strconv.ParseInt(iidStr, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的继承人 ID")
			return
		}
		var assetName, inName string
		if err := db.QueryRow(`SELECT a.name, i.name FROM asset_inheritors ai
			JOIN assets a ON a.id = ai.asset_id JOIN inheritors i ON i.id = ai.inheritor_id
			WHERE ai.asset_id = ? AND ai.id = ?`, assetID, iid).Scan(&assetName, &inName); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusNotFound, "绑定关系不存在")
				return
			}
			log.Printf("query unbind names: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		res, err := db.Exec(`DELETE FROM asset_inheritors WHERE asset_id = ? AND id = ?`, assetID, iid)
		if err != nil {
			log.Printf("delete asset inheritor: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "绑定关系不存在")
			return
		}
		logAudit(db, userID(r), fmt.Sprintf("解除继承人「%s」对资产「%s」的绑定", inName, assetName), map[string]any{"asset_id": assetID, "binding_id": iid})
		w.WriteHeader(http.StatusNoContent)
	}
}

// handleUpdateAssetInheritorLadder: PUT /api/v1/assets/{id}/inheritors/{iid} {ladder_id}
// -> 200 修改绑定的触发阶梯(ladder_id 为 null 时回退全局)。
func handleUpdateAssetInheritorLadder(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		assetID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		if !assetOwnedBy(db, assetID, uid) {
			writeError(w, http.StatusNotFound, "资产不存在")
			return
		}
		iid, err := strconv.ParseInt(r.PathValue("iid"), 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的继承人 ID")
			return
		}
		var req struct {
			LadderID *int64 `json:"ladder_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if req.LadderID != nil && !ladderOwnedBy(db, *req.LadderID, uid) {
			writeError(w, http.StatusBadRequest, "无效的触发阶梯")
			return
		}
		var assetName, inName string
		if err := db.QueryRow(`SELECT a.name, i.name FROM asset_inheritors ai
			JOIN assets a ON a.id = ai.asset_id JOIN inheritors i ON i.id = ai.inheritor_id
			WHERE ai.asset_id = ? AND ai.id = ?`, assetID, iid).Scan(&assetName, &inName); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusNotFound, "绑定关系不存在")
				return
			}
			log.Printf("query ladder names: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		res, err := db.Exec(`UPDATE asset_inheritors SET ladder_id = ? WHERE asset_id = ? AND id = ?`,
			nullableLadderID(req.LadderID), assetID, iid)
		if err != nil {
			log.Printf("update asset inheritor ladder: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "绑定关系不存在")
			return
		}
		logAudit(db, uid, fmt.Sprintf("修改资产「%s」继承人「%s」的触发阶梯", assetName, inName), map[string]any{"asset_id": assetID, "binding_id": iid, "ladder_id": req.LadderID})
		writeJSON(w, http.StatusOK, map[string]any{"id": iid, "ladder_id": req.LadderID})
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

// nullableLadderID converts a *int64 ladder id to nil (NULL=全局阶梯)。
func nullableLadderID(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}

// ---------- category (group) inheritors ----------

type categoryInheritorJSON struct {
	ID            int64  `json:"id"`
	CategoryID    int64  `json:"category_id"`
	InheritorID   int64  `json:"inheritor_id"`
	InheritorName string `json:"inheritor_name"`
	Priority      int    `json:"priority"`
	TriggerDays   *int   `json:"trigger_days"`
	LadderID      *int64 `json:"ladder_id"`   // NULL=全局阶梯
	LadderName    string `json:"ladder_name"` // 空=全局阶梯
}

// handleListCategoryInheritors: GET /api/v1/categories/{id}/inheritors
func handleListCategoryInheritors(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		catID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM categories WHERE id = ? AND user_id = ?`,
			catID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusNotFound, "分组不存在")
			return
		}
		rows, err := db.Query(`SELECT ci.id, ci.category_id, ci.inheritor_id, i.name,
				ci.priority, ci.trigger_days, ci.ladder_id, COALESCE(tl.name, '')
			FROM category_inheritors ci JOIN inheritors i ON i.id = ci.inheritor_id
			LEFT JOIN trigger_ladders tl ON tl.id = ci.ladder_id
			WHERE ci.category_id = ? ORDER BY ci.priority, ci.id`, catID)
		if err != nil {
			log.Printf("list category inheritors: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		list := []categoryInheritorJSON{}
		for rows.Next() {
			var a categoryInheritorJSON
			var td sql.NullInt64
			var lid sql.NullInt64
			if err := rows.Scan(&a.ID, &a.CategoryID, &a.InheritorID, &a.InheritorName, &a.Priority, &td, &lid, &a.LadderName); err != nil {
				log.Printf("scan category inheritor: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if td.Valid {
				n := int(td.Int64)
				a.TriggerDays = &n
			}
			if lid.Valid {
				n := lid.Int64
				a.LadderID = &n
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
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		var req assetInheritorRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM categories WHERE id = ? AND user_id = ?`,
			catID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusNotFound, "分组不存在")
			return
		}
		if err := db.QueryRow(`SELECT COUNT(*) FROM inheritors WHERE id = ? AND user_id = ?`,
			req.InheritorID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusBadRequest, "无效的继承人")
			return
		}
		if req.LadderID != nil && !ladderOwnedBy(db, *req.LadderID, uid) {
			writeError(w, http.StatusBadRequest, "无效的触发阶梯")
			return
		}
		priority := req.Priority
		if priority < 1 {
			priority = 1
		}
		res, err := db.Exec(`INSERT INTO category_inheritors (category_id, inheritor_id, priority, trigger_days, ladder_id)
			VALUES (?, ?, ?, ?, ?)`,
			catID, req.InheritorID, priority, nullableInt(req.TriggerDays), nullableLadderID(req.LadderID))
		if err != nil {
			log.Printf("insert category inheritor: %v", err)
			writeError(w, http.StatusBadRequest, "该继承人已绑定此分组")
			return
		}
		id, _ := res.LastInsertId()
		var catName, inName string
		if err := db.QueryRow(`SELECT c.name, i.name FROM categories c JOIN inheritors i ON i.id = ?
			WHERE c.id = ? AND c.user_id = ? AND i.user_id = ?`,
			req.InheritorID, catID, uid, uid).Scan(&catName, &inName); err != nil {
			log.Printf("query bind names: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		logAudit(db, userID(r), fmt.Sprintf("将继承人「%s」绑定为分组「%s」的继承人", inName, catName), map[string]any{"category_id": catID, "inheritor_id": req.InheritorID})
		writeJSON(w, http.StatusCreated, map[string]any{"id": id})
	}
}

// handleDeleteCategoryInheritor: DELETE /api/v1/categories/{id}/inheritors/{iid}
func handleDeleteCategoryInheritor(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		catID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM categories WHERE id = ? AND user_id = ?`,
			catID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusNotFound, "分组不存在")
			return
		}
		iidStr := r.PathValue("iid")
		iid, err := strconv.ParseInt(iidStr, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的继承人 ID")
			return
		}
		var catName, inName string
		if err := db.QueryRow(`SELECT c.name, i.name FROM category_inheritors ci
			JOIN categories c ON c.id = ci.category_id JOIN inheritors i ON i.id = ci.inheritor_id
			WHERE ci.category_id = ? AND ci.id = ?`, catID, iid).Scan(&catName, &inName); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusNotFound, "绑定关系不存在")
				return
			}
			log.Printf("query unbind names: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		res, err := db.Exec(`DELETE FROM category_inheritors WHERE category_id = ? AND id = ?`, catID, iid)
		if err != nil {
			log.Printf("delete category inheritor: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "绑定关系不存在")
			return
		}
		logAudit(db, userID(r), fmt.Sprintf("解除继承人「%s」对分组「%s」的绑定", inName, catName), map[string]any{"category_id": catID, "binding_id": iid})
		w.WriteHeader(http.StatusNoContent)
	}
}

// handleUpdateCategoryInheritorLadder: PUT /api/v1/categories/{id}/inheritors/{iid} {ladder_id}
// -> 200 修改绑定的触发阶梯(ladder_id 为 null 时回退全局)。
func handleUpdateCategoryInheritorLadder(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		catID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM categories WHERE id = ? AND user_id = ?`,
			catID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusNotFound, "分组不存在")
			return
		}
		iid, err := strconv.ParseInt(r.PathValue("iid"), 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的继承人 ID")
			return
		}
		var req struct {
			LadderID *int64 `json:"ladder_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if req.LadderID != nil && !ladderOwnedBy(db, *req.LadderID, uid) {
			writeError(w, http.StatusBadRequest, "无效的触发阶梯")
			return
		}
		var catName, inName string
		if err := db.QueryRow(`SELECT c.name, i.name FROM category_inheritors ci
			JOIN categories c ON c.id = ci.category_id JOIN inheritors i ON i.id = ci.inheritor_id
			WHERE ci.category_id = ? AND ci.id = ?`, catID, iid).Scan(&catName, &inName); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusNotFound, "绑定关系不存在")
				return
			}
			log.Printf("query ladder names: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		res, err := db.Exec(`UPDATE category_inheritors SET ladder_id = ? WHERE category_id = ? AND id = ?`,
			nullableLadderID(req.LadderID), catID, iid)
		if err != nil {
			log.Printf("update category inheritor ladder: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "绑定关系不存在")
			return
		}
		logAudit(db, uid, fmt.Sprintf("修改分组「%s」继承人「%s」的触发阶梯", catName, inName), map[string]any{"category_id": catID, "binding_id": iid, "ladder_id": req.LadderID})
		writeJSON(w, http.StatusOK, map[string]any{"id": iid, "ladder_id": req.LadderID})
	}
}

// handleListCategoryInheritorAssets: GET /api/v1/categories/{id}/inheritors/{iid}/assets
// -> 经该分组绑定继承的资产列表(排除已资产级绑定的资产),供继承预览。
func handleListCategoryInheritorAssets(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		catID, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		iidStr := r.PathValue("iid")
		iid, err := strconv.ParseInt(iidStr, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的继承人 ID")
			return
		}
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM category_inheritors ci
			JOIN categories c ON c.id = ci.category_id
			WHERE ci.id = ? AND ci.category_id = ? AND c.user_id = ?`, iid, catID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusNotFound, "绑定关系不存在")
			return
		}
		rows, err := db.Query(`SELECT a.id, a.name, a.asset_type, a.expiry_date
			FROM assets a
			WHERE a.category_id = ? AND a.user_id = ?
				AND NOT EXISTS (SELECT 1 FROM asset_inheritors ai2 WHERE ai2.asset_id = a.id)
			ORDER BY a.name`, catID, uid)
		if err != nil {
			log.Printf("list category inheritor assets: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
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
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
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
			writeError(w, http.StatusBadRequest, "无效的继承人 ID")
			return
		}
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM inheritors WHERE id = ? AND user_id = ?`,
			inID, uid).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusNotFound, "继承人不存在")
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
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
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
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
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
