package main

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
)

var errNotFound = errors.New("not found")

// nullable converts an empty string to NULL for SQL params (asset key wrapped
// fields are optional: legacy assets have none, client falls back to MK).
func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// handleBatchMoveAssets: POST /api/v1/assets/move {ids:[], category_id:null} ->
// {"moved":n}. 批量移动资产到目标分组(未分类整理);category_id 传 null = 移到未分类。
func handleBatchMoveAssets(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req struct {
			IDs        []int64 `json:"ids"`
			CategoryID *int64  `json:"category_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		if len(req.IDs) == 0 {
			writeError(w, http.StatusBadRequest, "ids required")
			return
		}
		if len(req.IDs) > 500 {
			writeError(w, http.StatusBadRequest, "too many ids")
			return
		}
		if req.CategoryID != nil {
			var n int
			if err := db.QueryRow(`SELECT COUNT(*) FROM categories WHERE id = ? AND user_id = ?`, *req.CategoryID, uid).Scan(&n); err != nil || n == 0 {
				writeError(w, http.StatusNotFound, "target category not found")
				return
			}
		}
		placeholders := strings.Repeat("?,", len(req.IDs)-1) + "?"
		args := make([]any, 0, len(req.IDs)+1)
		for _, id := range req.IDs {
			args = append(args, id)
		}
		args = append(args, uid)
		var cat any
		if req.CategoryID != nil {
			cat = *req.CategoryID
		}
		res, err := db.Exec(`UPDATE assets SET category_id = ?, updated_at = datetime('now')
			WHERE id IN (`+placeholders+`) AND user_id = ?`, append([]any{cat}, args...)...)
		if err != nil {
			log.Printf("batch move assets: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		n, _ := res.RowsAffected()
		logApp(db, userID(r), "移动资产", map[string]any{"ids": req.IDs, "category_id": req.CategoryID})
		writeJSON(w, http.StatusOK, map[string]int64{"moved": n})
	}
}

// ---------- assets ----------

// assetListJSON is the metadata-only shape returned by the list endpoint
// (encrypted_data is deliberately excluded).
type assetListJSON struct {
	ID         int64   `json:"id"`
	Name       string  `json:"name"`
	AssetType  string  `json:"asset_type"`
	CategoryID *int64  `json:"category_id"`
	ExpiryDate *string `json:"expiry_date"`
	Status     string  `json:"status"`
	UpdatedAt  string  `json:"updated_at"`
}

// assetJSON is the full shape; EncryptedData is the base64 re-encoded blob.
type assetJSON struct {
	assetListJSON
	EncryptedData      string `json:"encrypted_data"`
	AssetKeyWrappedMk  string `json:"asset_key_wrapped_mk,omitempty"`
	AssetKeyWrappedWk  string `json:"asset_key_wrapped_wk,omitempty"`
}

type assetRequest struct {
	Name               string  `json:"name"`
	AssetType          string  `json:"asset_type"`
	CategoryID         *int64  `json:"category_id"`
	EncryptedData      string  `json:"encrypted_data"`
	AssetKeyWrappedMk  string  `json:"asset_key_wrapped_mk"`
	AssetKeyWrappedWk  string  `json:"asset_key_wrapped_wk"`
	ExpiryDate         *string `json:"expiry_date"`
	Status             string  `json:"status"`
}

// validateAsset returns a 400 message, or ("", err) for internal DB errors.
func validateAsset(db *sql.DB, uid int64, req *assetRequest) (string, error) {
	if strings.TrimSpace(req.Name) == "" {
		return "name is required", nil
	}
	if req.AssetType != "physical" && req.AssetType != "virtual" {
		return "asset_type must be physical or virtual", nil
	}
	if strings.TrimSpace(req.EncryptedData) == "" {
		return "encrypted_data is required", nil
	}
	if _, err := base64.StdEncoding.DecodeString(req.EncryptedData); err != nil {
		return "encrypted_data must be base64", nil
	}
	if req.AssetKeyWrappedMk != "" {
		if _, err := base64.StdEncoding.DecodeString(req.AssetKeyWrappedMk); err != nil {
			return "asset_key_wrapped_mk must be base64", nil
		}
	}
	if req.AssetKeyWrappedWk != "" {
		if _, err := base64.StdEncoding.DecodeString(req.AssetKeyWrappedWk); err != nil {
			return "asset_key_wrapped_wk must be base64", nil
		}
	}
	if req.ExpiryDate != nil && strings.TrimSpace(*req.ExpiryDate) == "" {
		return "expiry_date must be a non-empty string if provided", nil
	}
	if req.CategoryID != nil {
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM categories WHERE id = ? AND user_id = ?`, *req.CategoryID, uid).
			Scan(&n); err != nil {
			return "", err
		}
		if n == 0 {
			return "invalid category", nil
		}
	}
	return "", nil
}

// fetchAsset loads one asset scoped to the owner; returns errNotFound if absent.
func fetchAsset(db *sql.DB, id, uid int64) (*assetJSON, error) {
	var a assetJSON
	var catID sql.NullInt64
	var exp sql.NullString
	var data []byte
	var wkMk, wkWk sql.NullString
	err := db.QueryRow(`SELECT id, name, asset_type, category_id, encrypted_data,
			expiry_date, status, updated_at, asset_key_wrapped_mk, asset_key_wrapped_wk
		FROM assets WHERE id = ? AND user_id = ? AND deleted_at IS NULL`, id, uid).
		Scan(&a.ID, &a.Name, &a.AssetType, &catID, &data, &exp, &a.Status, &a.UpdatedAt, &wkMk, &wkWk)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, errNotFound
	}
	if err != nil {
		return nil, err
	}
	if catID.Valid {
		a.CategoryID = &catID.Int64
	}
	if exp.Valid {
		a.ExpiryDate = &exp.String
	}
	if wkMk.Valid {
		a.AssetKeyWrappedMk = wkMk.String
	}
	if wkWk.Valid {
		a.AssetKeyWrappedWk = wkWk.String
	}
	a.EncryptedData = base64.StdEncoding.EncodeToString(data)
	return &a, nil
}

// handleListAssets: GET /api/v1/assets -> 200 metadata only (排除回收站)
func handleListAssets(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT id, name, asset_type, category_id, expiry_date, status, updated_at
			FROM assets WHERE user_id = ? AND deleted_at IS NULL ORDER BY id`, userID(r))
		if err != nil {
			log.Printf("list assets: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		list := []assetListJSON{}
		for rows.Next() {
			var a assetListJSON
			var catID sql.NullInt64
			var exp sql.NullString
			if err := rows.Scan(&a.ID, &a.Name, &a.AssetType, &catID, &exp, &a.Status, &a.UpdatedAt); err != nil {
				log.Printf("scan asset: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			if catID.Valid {
				a.CategoryID = &catID.Int64
			}
			if exp.Valid {
				a.ExpiryDate = &exp.String
			}
			list = append(list, a)
		}
		writeJSON(w, http.StatusOK, list)
	}
}

// handleGetAsset: GET /api/v1/assets/{id} -> 200 full (encrypted_data base64)
func handleGetAsset(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		a, err := fetchAsset(db, id, userID(r))
		if errors.Is(err, errNotFound) {
			writeError(w, http.StatusNotFound, "asset not found")
			return
		}
		if err != nil {
			log.Printf("get asset: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, a)
	}
}

// freeAssetQuota is defined as a package var in config.go (admin-configurable
// via config.json free_asset_quota); default 50.

// assetCount returns how many assets uid owns.
func assetCount(db *sql.DB, uid int64) (int, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(*) FROM assets WHERE user_id = ?`, uid).Scan(&n)
	return n, err
}

// handleCreateAsset: POST /api/v1/assets -> 201 full object
func handleCreateAsset(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req assetRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		uid := userID(r)
		if msg, err := validateAsset(db, uid, &req); err != nil {
			log.Printf("validate asset: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		} else if msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		// free-tier quota check (members unlimited)
		var tier string
		if err := db.QueryRow(`SELECT tier FROM users WHERE id = ?`, uid).Scan(&tier); err != nil {
			log.Printf("query user tier: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if tier == "free" {
			n, err := assetCount(db, uid)
			if err != nil {
				log.Printf("count assets: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			if n >= freeAssetQuota {
				writeError(w, http.StatusForbidden, fmt.Sprintf("免费用户最多 %d 条资产,升级会员可解锁", freeAssetQuota))
				return
			}
		}
		data, _ := base64.StdEncoding.DecodeString(req.EncryptedData)
		res, err := db.Exec(`INSERT INTO assets (user_id, category_id, asset_type, name, encrypted_data, expiry_date,
				asset_key_wrapped_mk, asset_key_wrapped_wk)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			uid, req.CategoryID, req.AssetType, req.Name, data, req.ExpiryDate,
			nullable(req.AssetKeyWrappedMk), nullable(req.AssetKeyWrappedWk))
		if err != nil {
			log.Printf("insert asset: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		id, _ := res.LastInsertId()
		a, err := fetchAsset(db, id, uid)
		if err != nil {
			log.Printf("fetch created asset: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		logAudit(db, uid, "新增资产", map[string]any{"id": id, "name": a.Name})
		writeJSON(w, http.StatusCreated, a)
	}
}

// handleUpdateAsset: PUT /api/v1/assets/{id} -> 200 updated object; 404 not owned
func handleUpdateAsset(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		uid := userID(r)
		var req assetRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		if msg, err := validateAsset(db, uid, &req); err != nil {
			log.Printf("validate asset: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		} else if msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		status := req.Status
		if status == "" {
			status = "active"
		}
		if status != "active" && status != "inactive" && status != "pending" && status != "expired" {
			writeError(w, http.StatusBadRequest, "invalid status")
			return
		}
		data, _ := base64.StdEncoding.DecodeString(req.EncryptedData)
		res, err := db.Exec(`UPDATE assets SET category_id = ?, asset_type = ?, name = ?, encrypted_data = ?,
			expiry_date = ?, status = ?, updated_at = datetime('now'), asset_key_wrapped_mk = ?, asset_key_wrapped_wk = ?
			WHERE id = ? AND user_id = ?`,
			req.CategoryID, req.AssetType, req.Name, data, req.ExpiryDate, status,
			nullable(req.AssetKeyWrappedMk), nullable(req.AssetKeyWrappedWk), id, uid)
		if err != nil {
			log.Printf("update asset: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "asset not found")
			return
		}
		a, err := fetchAsset(db, id, uid)
		if err != nil {
			log.Printf("fetch updated asset: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		logAudit(db, uid, "修改资产", map[string]any{"id": id, "name": a.Name})
		writeJSON(w, http.StatusOK, a)
	}
}

// handleDeleteAsset: DELETE /api/v1/assets/{id} -> 204; 404 not owned.
// 软删除(deleted_at = now)进回收站,恢复见 handleRestoreItem。
func handleDeleteAsset(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		res, err := db.Exec(`UPDATE assets SET deleted_at = datetime('now') WHERE id = ? AND user_id = ? AND deleted_at IS NULL`, id, userID(r))
		if err != nil {
			log.Printf("soft delete asset: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "asset not found")
			return
		}
		logAudit(db, userID(r), "删除资产", map[string]any{"id": id})
		w.WriteHeader(http.StatusNoContent)
	}
}

// handleCopyAsset: POST /api/v1/assets/{id}/copy -> 201 复制资产(新 id,名称加"副本")。
func handleCopyAsset(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		uid := userID(r)
		var src assetJSON
		var catID sql.NullInt64
		var exp sql.NullString
		var data []byte
		var wkMk, wkWk sql.NullString
		if err := db.QueryRow(`SELECT id, name, asset_type, category_id, encrypted_data,
			expiry_date, status, asset_key_wrapped_mk, asset_key_wrapped_wk
			FROM assets WHERE id = ? AND user_id = ? AND deleted_at IS NULL`, id, uid).
			Scan(&src.ID, &src.Name, &src.AssetType, &catID, &data, &exp, &src.Status, &wkMk, &wkWk); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusNotFound, "asset not found")
				return
			}
			log.Printf("copy asset query: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if src.Status == "" {
			src.Status = "active"
		}
		// 名称加"副本"后缀。
		newName := src.Name + " 副本"
		res, err := db.Exec(`INSERT INTO assets (user_id, category_id, asset_type, name, encrypted_data, expiry_date,
				status, asset_key_wrapped_mk, asset_key_wrapped_wk)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			uid, nullableInt64(catID), src.AssetType, newName, data, nullableStr(exp),
			src.Status, nullable(wkMk.String), nullable(wkWk.String))
		if err != nil {
			log.Printf("copy asset insert: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		newID, _ := res.LastInsertId()
		a, err := fetchAsset(db, newID, uid)
		if err != nil {
			log.Printf("fetch copied asset: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		logAudit(db, uid, "复制资产", map[string]any{"source_id": id, "new_id": newID, "name": a.Name})
		writeJSON(w, http.StatusCreated, a)
	}
}

// nullableInt64 converts an invalid sql.NullInt64 to nil.
func nullableInt64(v sql.NullInt64) any {
	if !v.Valid {
		return nil
	}
	return v.Int64
}

// nullableStr converts an invalid sql.NullString to nil.
func nullableStr(v sql.NullString) any {
	if !v.Valid {
		return nil
	}
	return v.String
}
