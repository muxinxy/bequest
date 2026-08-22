package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

// hashAccessCode stores access codes as sha256 hex. Codes are 256-bit random
// strings (high entropy), so sha256 is a sufficient one-way store — plaintext
// is never persisted.
func hashAccessCode(code string) string {
	sum := sha256.Sum256([]byte(code))
	return hex.EncodeToString(sum[:])
}

// accessCodeMatches compares a stored hash against a candidate code in
// constant time (crypto/subtle), avoiding a timing side channel.
func accessCodeMatches(storedHash, code string) bool {
	return subtle.ConstantTimeCompare([]byte(storedHash), []byte(hashAccessCode(code))) == 1
}

// ---------- inheritors ----------

type inheritorJSON struct {
	ID            int64  `json:"id"`
	Name          string `json:"name"`
	Email         string `json:"email"`
	Priority      int    `json:"priority"`
	CreatedAt     string `json:"created_at"`
	AssetCount    int    `json:"asset_count"`    // 绑定的资产数量
	CategoryCount int    `json:"category_count"` // 绑定的分组数量
	AccessCode    string `json:"access_code"`    // 明文(用户本人数据;claim 验证仍用 hash)
}

type inheritorRequest struct {
	Name       string `json:"name"`
	Email      string `json:"email"`
	AccessCode string `json:"access_code"`
}

// fetchInheritor loads one inheritor scoped to the owner; errNotFound if absent.
func fetchInheritor(db *sql.DB, id, uid int64) (*inheritorJSON, error) {
	var in inheritorJSON
	err := db.QueryRow(`SELECT id, name, email, priority, created_at, COALESCE(access_code, '')
		FROM inheritors WHERE id = ? AND user_id = ?`, id, uid).
		Scan(&in.ID, &in.Name, &in.Email, &in.Priority, &in.CreatedAt, &in.AccessCode)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, errNotFound
	}
	if err != nil {
		return nil, err
	}
	return &in, nil
}

func validateInheritor(req inheritorRequest) string {
	if strings.TrimSpace(req.Name) == "" || strings.TrimSpace(req.Email) == "" || strings.TrimSpace(req.AccessCode) == "" {
		return "名称、邮箱和访问码均必填"
	}
	return ""
}

// handleListInheritors: GET /api/v1/inheritors -> 200 [] (access_code_hash never exposed)
func handleListInheritors(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT i.id, i.name, i.email, i.priority, i.created_at,
			(SELECT COUNT(*) FROM asset_inheritors ai WHERE ai.inheritor_id = i.id),
			(SELECT COUNT(*) FROM category_inheritors ci WHERE ci.inheritor_id = i.id),
			COALESCE(i.access_code, '')
			FROM inheritors i WHERE i.user_id = ? ORDER BY i.priority, i.id`, userID(r))
		if err != nil {
			log.Printf("list inheritors: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		list := []inheritorJSON{}
		for rows.Next() {
			var in inheritorJSON
			if err := rows.Scan(&in.ID, &in.Name, &in.Email, &in.Priority, &in.CreatedAt, &in.AssetCount, &in.CategoryCount, &in.AccessCode); err != nil {
				log.Printf("scan inheritor: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			list = append(list, in)
		}
		writeJSON(w, http.StatusOK, list)
	}
}

// handleCreateInheritor: POST /api/v1/inheritors -> 201; 400 empty fields
func handleCreateInheritor(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req inheritorRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if msg := validateInheritor(req); msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		res, err := db.Exec(`INSERT INTO inheritors (user_id, name, email, access_code_hash, access_code) VALUES (?, ?, ?, ?, ?)`,
			userID(r), strings.TrimSpace(req.Name), strings.TrimSpace(req.Email), hashAccessCode(req.AccessCode), strings.TrimSpace(req.AccessCode))
		if err != nil {
			log.Printf("insert inheritor: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		id, _ := res.LastInsertId()
		in, err := fetchInheritor(db, id, userID(r))
		if err != nil {
			log.Printf("fetch created inheritor: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		logAudit(db, userID(r), fmt.Sprintf("新增继承人「%s」", in.Name), map[string]any{"id": id})
		writeJSON(w, http.StatusCreated, in)
	}
}

// handleUpdateInheritor: PUT /api/v1/inheritors/{id} -> 200; 404 not owned;
// access_code only re-hashed when provided.
func handleUpdateInheritor(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		var req inheritorRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if strings.TrimSpace(req.Name) == "" || strings.TrimSpace(req.Email) == "" {
			writeError(w, http.StatusBadRequest, "名称和邮箱必填")
			return
		}
		// only re-hash when a new access code is supplied
		if req.AccessCode != "" {
			res, err := db.Exec(`UPDATE inheritors SET name = ?, email = ?, access_code_hash = ?, access_code = ? WHERE id = ? AND user_id = ?`,
				strings.TrimSpace(req.Name), strings.TrimSpace(req.Email), hashAccessCode(req.AccessCode), strings.TrimSpace(req.AccessCode), id, uid)
			if err != nil {
				log.Printf("update inheritor: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if n, _ := res.RowsAffected(); n == 0 {
				writeError(w, http.StatusNotFound, "继承人不存在")
				return
			}
		} else {
			res, err := db.Exec(`UPDATE inheritors SET name = ?, email = ? WHERE id = ? AND user_id = ?`,
				strings.TrimSpace(req.Name), strings.TrimSpace(req.Email), id, uid)
			if err != nil {
				log.Printf("update inheritor: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if n, _ := res.RowsAffected(); n == 0 {
				writeError(w, http.StatusNotFound, "继承人不存在")
				return
			}
		}
		in, err := fetchInheritor(db, id, uid)
		if err != nil {
			log.Printf("fetch updated inheritor: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		logAudit(db, uid, fmt.Sprintf("修改继承人信息「%s」", in.Name), map[string]any{"id": id})
		writeJSON(w, http.StatusOK, in)
	}
}

// handleDeleteInheritor: DELETE /api/v1/inheritors/{id} -> 204; 404 not owned
func handleDeleteInheritor(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		var name string
		if err := db.QueryRow(`SELECT name FROM inheritors WHERE id = ? AND user_id = ?`, id, uid).Scan(&name); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusNotFound, "继承人不存在")
				return
			}
			log.Printf("query inheritor name: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		res, err := db.Exec(`DELETE FROM inheritors WHERE id = ? AND user_id = ?`, id, uid)
		if err != nil {
			log.Printf("delete inheritor: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "继承人不存在")
			return
		}
		logAudit(db, uid, fmt.Sprintf("删除继承人「%s」", name), map[string]any{"id": id})
		w.WriteHeader(http.StatusNoContent)
	}
}

// ---------- claim & status ----------

type claimRequest struct {
	EventKey   string `json:"event_key"`
	AccessCode string `json:"access_code"`
}

// handleClaim: POST /api/v1/inheritance/claim (NO auth) ->
// 200 {master_key_wrapped, status:"claimed"}; 401 unknown event or bad code;
// 409 event not pending.
func handleClaim(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req claimRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		var eventID int64
		var status, codeHash string
		var ownerID int64
		var mkw []byte
		var assetID sql.NullInt64
		err := db.QueryRow(`SELECT e.id, e.status, e.access_code_hash, e.user_id, u.master_key_wrapped, e.asset_id
			FROM inheritance_events e JOIN users u ON u.id = e.user_id WHERE e.event_key = ?`, req.EventKey).
			Scan(&eventID, &status, &codeHash, &ownerID, &mkw, &assetID)
		if errors.Is(err, sql.ErrNoRows) {
			// 未知 event_key:审计(ownerID 未知,user_id 记 0;actor 区分来源)。
			if _, aerr := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (0, 'system', 'claim_failed', ?)`,
				"unknown event_key"); aerr != nil {
				log.Printf("audit claim fail: %v", aerr)
			}
			writeError(w, http.StatusUnauthorized, "无效的 event_key 或访问码")
			return
		}
		if err != nil {
			log.Printf("query claim event: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if !accessCodeMatches(codeHash, req.AccessCode) {
			if _, aerr := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (?, 'inheritor', 'claim_failed', ?)`,
				ownerID, "wrong access_code"); aerr != nil {
				log.Printf("audit claim fail: %v", aerr)
			}
			writeError(w, http.StatusUnauthorized, "无效的 event_key 或访问码")
			return
		}
		if status != "pending" {
			writeError(w, http.StatusConflict, "交接事件已被领取或已撤销")
			return
		}
		res, err := db.Exec(`UPDATE inheritance_events SET status = 'claimed', claimed_at = datetime('now'),
				reversable_until = datetime('now', '+72 hours')
			WHERE id = ? AND status = 'pending'`, eventID)
		if err != nil {
			log.Printf("claim event: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusConflict, "交接事件已被领取或已撤销")
			return
		}
		if _, err := db.Exec(`UPDATE users SET inherit_stage = 'claimed' WHERE id = ?`, ownerID); err != nil {
			log.Printf("set claimed stage: %v", err)
		}
		if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (?, ?, 'inheritance_claimed', ?)`,
			ownerID, fmt.Sprintf("inheritor:%d", eventID), req.EventKey); err != nil {
			log.Printf("audit claim: %v", err)
		}
		// 资产级事件:只发放该资产的继承包装密钥(继承人凭 WK 解出该资产 AK);
		// 全量事件:发放用户级主密钥包装(现有行为)。
		revUntil := time.Now().UTC().Add(72 * time.Hour).Format("2006-01-02 15:04:05")
		if assetID.Valid {
			var wk string
			if err := db.QueryRow(`SELECT asset_key_wrapped_wk FROM assets WHERE id = ?`, assetID.Int64).Scan(&wk); err != nil || wk == "" {
				log.Printf("claim asset key: asset=%d err=%v", assetID.Int64, err)
				writeError(w, http.StatusInternalServerError, "资产密钥缺失")
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{
				"asset_key_wrapped_wk": wk,
				"asset_id":             assetID.Int64,
				"status":               "claimed",
				"reversable_until":     revUntil,
			})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"master_key_wrapped": base64.StdEncoding.EncodeToString(mkw),
			"status":             "claimed",
			"reversable_until":   revUntil,
		})
	}
}

type eventJSON struct {
	ID              int64   `json:"id"`
	Status          string  `json:"status"`
	AssetID         *int64  `json:"asset_id"`
	AssetName       *string `json:"asset_name"`
	CreatedAt       string  `json:"created_at"`
	ClaimedAt       *string `json:"claimed_at"`
	ReversedAt      *string `json:"reversed_at"`
	ReversableUntil *string `json:"reversable_until"` // claimed 事件的反悔截止
}

// handleInheritanceStatus: GET /api/v1/inheritance/status -> 200
// {stage, escalation_level, last_login_at, events[]} newest event first.
func handleInheritanceStatus(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var stage string
		var escLevel int
		var lastLogin sql.NullString
		if err := db.QueryRow(`SELECT inherit_stage, escalation_level, last_login_at FROM users WHERE id = ?`, uid).
			Scan(&stage, &escLevel, &lastLogin); err != nil {
			log.Printf("query status: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		var ll *string
		if lastLogin.Valid {
			ll = &lastLogin.String
		}
		rows, err := db.Query(`SELECT e.id, e.status, e.created_at, e.claimed_at, e.reversed_at, e.reversable_until,
				e.asset_id, a.name
			FROM inheritance_events e LEFT JOIN assets a ON a.id = e.asset_id
			WHERE e.user_id = ? ORDER BY e.id DESC`, uid)
		if err != nil {
			log.Printf("list events: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		events := []eventJSON{}
		for rows.Next() {
			var e eventJSON
			var claimed, reversed, revUntil sql.NullString
			var assetID sql.NullInt64
			var assetName sql.NullString
			if err := rows.Scan(&e.ID, &e.Status, &e.CreatedAt, &claimed, &reversed, &revUntil, &assetID, &assetName); err != nil {
				log.Printf("scan event: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if claimed.Valid {
				e.ClaimedAt = &claimed.String
			}
			if reversed.Valid {
				e.ReversedAt = &reversed.String
			}
			if revUntil.Valid {
				e.ReversableUntil = &revUntil.String
			}
			if assetID.Valid {
				e.AssetID = &assetID.Int64
			}
			if assetName.Valid {
				e.AssetName = &assetName.String
			}
			events = append(events, e)
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"stage":            stage,
			"escalation_level": escLevel,
			"last_login_at":    ll,
			"events":           events,
		})
	}
}
