package main

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
)

var errNotFound = errors.New("not found")

// ---------- assets ----------

// assetListJSON is the metadata-only shape returned by the list endpoint
// (encrypted_data is deliberately excluded).
type assetListJSON struct {
	ID         int64   `json:"id"`
	Name       string  `json:"name"`
	AssetType  string  `json:"asset_type"`
	CategoryID *int64  `json:"category_id"`
	ExpiryDate *string `json:"expiry_date"`
	UpdatedAt  string  `json:"updated_at"`
}

// assetJSON is the full shape; EncryptedData is the base64 re-encoded blob.
type assetJSON struct {
	assetListJSON
	EncryptedData string `json:"encrypted_data"`
}

type assetRequest struct {
	Name          string  `json:"name"`
	AssetType     string  `json:"asset_type"`
	CategoryID    *int64  `json:"category_id"`
	EncryptedData string  `json:"encrypted_data"`
	ExpiryDate    *string `json:"expiry_date"`
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
	err := db.QueryRow(`SELECT id, name, asset_type, category_id, encrypted_data, expiry_date, updated_at
		FROM assets WHERE id = ? AND user_id = ?`, id, uid).
		Scan(&a.ID, &a.Name, &a.AssetType, &catID, &data, &exp, &a.UpdatedAt)
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
	a.EncryptedData = base64.StdEncoding.EncodeToString(data)
	return &a, nil
}

// handleListAssets: GET /api/v1/assets -> 200 metadata only
func handleListAssets(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT id, name, asset_type, category_id, expiry_date, updated_at
			FROM assets WHERE user_id = ? ORDER BY id`, userID(r))
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
			if err := rows.Scan(&a.ID, &a.Name, &a.AssetType, &catID, &exp, &a.UpdatedAt); err != nil {
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

// freeAssetQuota is the asset cap for free-tier users; members are unlimited.
const freeAssetQuota = 50

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
				writeError(w, http.StatusForbidden, "免费用户最多 50 条资产,升级会员可解锁")
				return
			}
		}
		data, _ := base64.StdEncoding.DecodeString(req.EncryptedData)
		res, err := db.Exec(`INSERT INTO assets (user_id, category_id, asset_type, name, encrypted_data, expiry_date)
			VALUES (?, ?, ?, ?, ?, ?)`,
			uid, req.CategoryID, req.AssetType, req.Name, data, req.ExpiryDate)
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
		data, _ := base64.StdEncoding.DecodeString(req.EncryptedData)
		res, err := db.Exec(`UPDATE assets SET category_id = ?, asset_type = ?, name = ?, encrypted_data = ?,
			expiry_date = ?, updated_at = datetime('now') WHERE id = ? AND user_id = ?`,
			req.CategoryID, req.AssetType, req.Name, data, req.ExpiryDate, id, uid)
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
		writeJSON(w, http.StatusOK, a)
	}
}

// handleDeleteAsset: DELETE /api/v1/assets/{id} -> 204; 404 not owned
func handleDeleteAsset(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		res, err := db.Exec(`DELETE FROM assets WHERE id = ? AND user_id = ?`, id, userID(r))
		if err != nil {
			log.Printf("delete asset: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "asset not found")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}
