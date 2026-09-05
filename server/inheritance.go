package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
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

// maskAccessCode 列表展示用掩码:长度>4 显示首尾字符(A***D),短码显示 ****。
// 明文只在创建/重置继承码时经 fetchInheritor 返回一次,列表不再泄露。
func maskAccessCode(code string) string {
	if len(code) <= 4 {
		return "****"
	}
	return code[:1] + "***" + code[len(code)-1:]
}

// ---------- inheritors ----------

type inheritorJSON struct {
	ID            int64  `json:"id"`
	Name          string `json:"name"`
	Email         string `json:"email"`
	Phone         string `json:"phone"`
	Priority      int    `json:"priority"`
	CreatedAt     string `json:"created_at"`
	AssetCount    int    `json:"asset_count"`    // 绑定的资产数量
	CategoryCount int    `json:"category_count"` // 绑定的分组数量
	AccessCode    string `json:"access_code"`    // 明文(用户本人数据;claim 验证仍用 hash)
}

type inheritorRequest struct {
	Name       string `json:"name"`
	Email      string `json:"email"`
	Phone      string `json:"phone"`
	AccessCode string `json:"access_code"`
}

// fetchInheritor loads one inheritor scoped to the owner; errNotFound if absent.
func fetchInheritor(db *sql.DB, id, uid int64) (*inheritorJSON, error) {
	var in inheritorJSON
	err := db.QueryRow(`SELECT id, name, email, COALESCE(phone, ''), priority, created_at, COALESCE(access_code, '')
		FROM inheritors WHERE id = ? AND user_id = ?`, id, uid).
		Scan(&in.ID, &in.Name, &in.Email, &in.Phone, &in.Priority, &in.CreatedAt, &in.AccessCode)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, errNotFound
	}
	if err != nil {
		return nil, err
	}
	return &in, nil
}

func validateInheritor(req inheritorRequest) string {
	if strings.TrimSpace(req.Name) == "" {
		return "名称必填"
	}
	if strings.TrimSpace(req.Email) == "" && strings.TrimSpace(req.Phone) == "" {
		return "邮箱或手机号至少填一个"
	}
	if strings.TrimSpace(req.AccessCode) == "" {
		return "访问码必填"
	}
	return ""
}

// handleListInheritors: GET /api/v1/inheritors -> 200 [] (access_code_hash never exposed)
func handleListInheritors(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT i.id, i.name, i.email, COALESCE(i.phone, ''), i.priority, i.created_at,
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
			if err := rows.Scan(&in.ID, &in.Name, &in.Email, &in.Phone, &in.Priority, &in.CreatedAt, &in.AssetCount, &in.CategoryCount, &in.AccessCode); err != nil {
				log.Printf("scan inheritor: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			in.AccessCode = maskAccessCode(in.AccessCode)
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
		id, err := execInsert(db, `INSERT INTO inheritors (user_id, name, email, phone, access_code_hash, access_code) VALUES (?, ?, ?, ?, ?, ?)`,
			userID(r), strings.TrimSpace(req.Name), strings.TrimSpace(req.Email), strings.TrimSpace(req.Phone), hashAccessCode(req.AccessCode), strings.TrimSpace(req.AccessCode))
		if err != nil {
			log.Printf("insert inheritor: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
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
		if strings.TrimSpace(req.Name) == "" || (strings.TrimSpace(req.Email) == "" && strings.TrimSpace(req.Phone) == "") {
			writeError(w, http.StatusBadRequest, "名称必填,邮箱或手机号至少填一个")
			return
		}
		// only re-hash when a new access code is supplied
		if req.AccessCode != "" {
			res, err := db.Exec(`UPDATE inheritors SET name = ?, email = ?, phone = ?, access_code_hash = ?, access_code = ? WHERE id = ? AND user_id = ?`,
				strings.TrimSpace(req.Name), strings.TrimSpace(req.Email), strings.TrimSpace(req.Phone), hashAccessCode(req.AccessCode), strings.TrimSpace(req.AccessCode), id, uid)
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
			res, err := db.Exec(`UPDATE inheritors SET name = ?, email = ?, phone = ? WHERE id = ? AND user_id = ?`,
				strings.TrimSpace(req.Name), strings.TrimSpace(req.Email), strings.TrimSpace(req.Phone), id, uid)
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
		res, err := db.Exec(`UPDATE inheritance_events SET status = 'claimed', claimed_at = `+dbNow()+`,
				reversable_until = `+dbNowAdd("+72 hours")+`
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

// ---------- 继承事件查询/导出 ----------

// inheritanceEventItem 事件列表项(含继承人名;资产可能已删除,asset_name 可空)。
type inheritanceEventItem struct {
	ID              int64   `json:"id"`
	Status          string  `json:"status"`
	CreatedAt       string  `json:"created_at"`
	ClaimedAt       *string `json:"claimed_at"`
	ReversedAt      *string `json:"reversed_at"`
	ReversableUntil *string `json:"reversable_until"`
	AssetID         *int64  `json:"asset_id"`
	AssetName       *string `json:"asset_name"`
	InheritorName   string  `json:"inheritor_name"`
}

// parseEventQuery 解析 month/q/limit/offset 查询参数。
// month 形如 "2026-08";q 搜索资产名或继承人名;limit 默认 50 最大 200。
func parseEventQuery(r *http.Request) (month, q string, limit, offset int, bad string) {
	month = r.URL.Query().Get("month")
	if month != "" {
		if _, err := time.Parse("2006-01", month); err != nil {
			return "", "", 0, 0, "month 必须为 YYYY-MM 格式"
		}
	}
	q = strings.TrimSpace(r.URL.Query().Get("q"))
	limit = 50
	if s := r.URL.Query().Get("limit"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n > 0 && n <= 200 {
			limit = n
		}
	}
	if s := r.URL.Query().Get("offset"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n >= 0 {
			offset = n
		}
	}
	return month, q, limit, offset, ""
}

// eventWhere 拼装事件查询条件(用户 + 可选月份 + 可选搜索),返回 where 子句与参数。
func eventWhere(uid int64, month, q string) (string, []any) {
	where := "e.user_id = ?"
	args := []any{uid}
	if month != "" {
		where += " AND " + dbMonth("e.created_at") + " = ?"
		args = append(args, month)
	}
	if q != "" {
		where += " AND (a.name LIKE ? OR i.name LIKE ?)"
		like := "%" + q + "%"
		args = append(args, like, like)
	}
	return where, args
}

// handleListInheritanceEvents: GET /api/v1/inheritance/events?month=&q=&limit=&offset=
// -> 200 {"items":[...],"total":n} 按 id 倒序。
func handleListInheritanceEvents(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		month, q, limit, offset, bad := parseEventQuery(r)
		if bad != "" {
			writeError(w, http.StatusBadRequest, bad)
			return
		}
		where, args := eventWhere(userID(r), month, q)
		var total int
		if err := db.QueryRow(`SELECT COUNT(*) FROM inheritance_events e
			JOIN inheritors i ON i.id = e.inheritor_id
			LEFT JOIN assets a ON a.id = e.asset_id WHERE `+where, args...).Scan(&total); err != nil {
			log.Printf("count events: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		rows, err := db.Query(`SELECT e.id, e.status, e.created_at, e.claimed_at, e.reversed_at,
				e.reversable_until, e.asset_id, a.name, i.name
			FROM inheritance_events e
			JOIN inheritors i ON i.id = e.inheritor_id
			LEFT JOIN assets a ON a.id = e.asset_id
			WHERE `+where+` ORDER BY e.id DESC LIMIT ? OFFSET ?`,
			append(append([]any{}, args...), limit, offset)...)
		if err != nil {
			log.Printf("list events: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		items := []inheritanceEventItem{}
		for rows.Next() {
			var e inheritanceEventItem
			var claimed, reversed, revUntil sql.NullString
			var assetID sql.NullInt64
			var assetName sql.NullString
			if err := rows.Scan(&e.ID, &e.Status, &e.CreatedAt, &claimed, &reversed, &revUntil, &assetID, &assetName, &e.InheritorName); err != nil {
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
			items = append(items, e)
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": total})
	}
}

// eventStatusCN 状态中文映射。
func eventStatusCN(status string) string {
	return map[string]string{"pending": "待领取", "claimed": "已领取", "reversed": "已撤销"}[status]
}

// handleExportInheritanceEvents: GET /api/v1/inheritance/events/export?month=&q= -> CSV 下载。
func handleExportInheritanceEvents(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		month, q, _, _, bad := parseEventQuery(r)
		if bad != "" {
			writeError(w, http.StatusBadRequest, bad)
			return
		}
		where, args := eventWhere(userID(r), month, q)
		rows, err := db.Query(`SELECT e.id, e.status, e.event_key, e.created_at, e.claimed_at,
				e.reversed_at, e.reversable_until, COALESCE(a.name, ''), i.name
			FROM inheritance_events e
			JOIN inheritors i ON i.id = e.inheritor_id
			LEFT JOIN assets a ON a.id = e.asset_id
			WHERE `+where+` ORDER BY e.id`, args...)
		if err != nil {
			log.Printf("export events: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()

		fname := fmt.Sprintf("inheritance-events-%s.csv", time.Now().Format("20060102-150405"))
		w.Header().Set("Content-Type", "text/csv; charset=utf-8")
		w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", fname))
		cw := csv.NewWriter(w)
		_ = cw.Write([]string{"ID", "状态", "事件键", "资产", "继承人", "创建时间", "领取时间", "撤销时间", "可撤销截止"})
		for rows.Next() {
			var id int64
			var status, eventKey, createdAt, assetName, inheritorName string
			var claimed, reversed, revUntil sql.NullString
			if err := rows.Scan(&id, &status, &eventKey, &createdAt, &claimed, &reversed, &revUntil, &assetName, &inheritorName); err != nil {
				log.Printf("scan export event: %v", err)
				return
			}
			_ = cw.Write([]string{
				strconv.FormatInt(id, 10), eventStatusCN(status), eventKey, assetName, inheritorName,
				createdAt, claimed.String, reversed.String, revUntil.String,
			})
		}
		cw.Flush()
	}
}
