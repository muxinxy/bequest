package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------- 会员过期自动降级 ----------

// syncMemberTier 会员到期自动降级:仅当 tier='member' 且到期时间非空且已过 → 降为 free。
// member_expires_at 为空视为永久会员(兼容 admin 手动开通的会员),不过期。
func syncMemberTier(db *sql.DB, uid int64) {
	if _, err := db.Exec(`UPDATE users SET tier = 'free'
		WHERE id = ? AND tier = 'member' AND member_expires_at IS NOT NULL AND member_expires_at != '' AND member_expires_at < datetime('now')`, uid); err != nil {
		log.Printf("sync member tier: %v", err)
	}
}

// ---------- 用户兑换 ----------

// ---------- 兑换码防爆破(用户级失败计数) ----------
// IP 级限流挡不住换 IP 枚举;这里按 user_id 记连续失败次数,
// 连续 5 次失败后直接 429,兑换成功即清零,记录 5 分钟过期。

type redeemFail struct {
	count    int
	lastFail time.Time
}

var redeemFailures = struct {
	sync.Mutex
	m map[int64]*redeemFail
}{m: map[int64]*redeemFail{}}

// redeemFailRecord 记录一次兑换失败;返回 true 表示应限流(429)。
func redeemFailRecord(uid int64) bool {
	redeemFailures.Lock()
	defer redeemFailures.Unlock()
	now := time.Now()
	f, ok := redeemFailures.m[uid]
	if !ok || now.Sub(f.lastFail) > 5*time.Minute {
		// 首次失败或记录过期:重置计数
		redeemFailures.m[uid] = &redeemFail{count: 1, lastFail: now}
		return false
	}
	f.count++
	f.lastFail = now
	return f.count >= 5
}

// redeemFailClear 兑换成功后清除该用户计数。
func redeemFailClear(uid int64) {
	redeemFailures.Lock()
	defer redeemFailures.Unlock()
	delete(redeemFailures.m, uid)
}

// handleRedeemMembership: POST /api/v1/membership/redeem {code} -> 200 {tier, member_expires_at}
// 有效会员(未过期或永久)兑换则叠加时长,否则从当前时间起算。
func handleRedeemMembership(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req struct {
			Code string `json:"code"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		code := strings.TrimSpace(req.Code)
		if code == "" {
			writeError(w, http.StatusBadRequest, "兑换码不能为空")
			return
		}
		var rcID int64
		var durationDays int
		err := db.QueryRow(`SELECT id, duration_days FROM redemption_codes WHERE code = ? AND used_at IS NULL`, code).
			Scan(&rcID, &durationDays)
		if errors.Is(err, sql.ErrNoRows) {
			if redeemFailRecord(uid) {
				writeError(w, http.StatusTooManyRequests, "尝试次数过多,请稍后再试")
				return
			}
			writeError(w, http.StatusBadRequest, "兑换码无效或已被使用")
			return
		}
		if err != nil {
			log.Printf("query redemption code: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		// 当前会员状态:有效会员(未过期或永久)则叠加,否则从 now 起算。
		var tier, memberExpires string
		if err := db.QueryRow(`SELECT tier, COALESCE(member_expires_at, '') FROM users WHERE id = ?`, uid).
			Scan(&tier, &memberExpires); err != nil {
			log.Printf("query user tier: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		now := time.Now().UTC()
		base := now
		if tier == "member" && (memberExpires == "" || memberExpires > now.Format("2006-01-02 15:04:05")) {
			if t, err := time.Parse("2006-01-02 15:04:05", memberExpires); err == nil {
				base = t
			}
		}
		newExpires := base.AddDate(0, 0, durationDays).Format("2006-01-02 15:04:05")

		tx, err := db.Begin()
		if err != nil {
			log.Printf("begin redeem: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if _, err := tx.Exec(`UPDATE users SET tier = 'member', member_expires_at = ? WHERE id = ?`, newExpires, uid); err != nil {
			tx.Rollback()
			log.Printf("redeem update user: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if _, err := tx.Exec(`UPDATE redemption_codes SET used_by = ?, used_at = datetime('now') WHERE id = ?`, uid, rcID); err != nil {
			tx.Rollback()
			log.Printf("redeem mark used: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if err := tx.Commit(); err != nil {
			log.Printf("commit redeem: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		redeemFailClear(uid)
		logAudit(db, uid, "兑换会员", map[string]any{"code": code})
		writeJSON(w, http.StatusOK, map[string]any{"tier": "member", "member_expires_at": newExpires})
	}
}

// ---------- admin 兑换码管理 ----------

// 生成码字符集:大写字母+数字,去掉易混淆字符 0O1IL。
const codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

// genRedemptionCode 生成 XXXX-XXXX-XXXX 格式随机码(crypto/rand)。
func genRedemptionCode() string {
	b := make([]byte, 12)
	for i := range b {
		b[i] = codeAlphabet[mustRandomInt(len(codeAlphabet))]
	}
	return string(b[0:4]) + "-" + string(b[4:8]) + "-" + string(b[8:12])
}

type redemptionCodeJSON struct {
	ID              int64  `json:"id"`
	Code            string `json:"code"`
	DurationDays    int    `json:"duration_days"`
	UsedBy          any    `json:"used_by"`
	UsedByUsername  string `json:"used_by_username"`
	UsedAt          any    `json:"used_at"`
	CreatedAt       string `json:"created_at"`
}

// handleListRedemptionCodes: GET /api/v1/admin/redemption-codes -> 最新在前,
// 分页 {"items":[...], "total":n, "page":p}。page 默认 1,page_size 默认 20 最大 100。
func handleListRedemptionCodes(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		page := 1
		if v := r.URL.Query().Get("page"); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 {
				writeError(w, http.StatusBadRequest, "无效的 page")
				return
			}
			page = n
		}
		pageSize := 20
		if v := r.URL.Query().Get("page_size"); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 {
				writeError(w, http.StatusBadRequest, "无效的 page_size")
				return
			}
			if n > 100 {
				n = 100
			}
			pageSize = n
		}
		var total int
		if err := db.QueryRow(`SELECT COUNT(*) FROM redemption_codes`).Scan(&total); err != nil {
			log.Printf("count redemption codes: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		rows, err := db.Query(`SELECT rc.id, rc.code, rc.duration_days, rc.used_by, rc.used_at, rc.created_at,
			COALESCE(u.username, '')
			FROM redemption_codes rc LEFT JOIN users u ON u.id = rc.used_by
			ORDER BY rc.id DESC LIMIT ? OFFSET ?`, pageSize, (page-1)*pageSize)
		if err != nil {
			log.Printf("list redemption codes: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		codes := []redemptionCodeJSON{}
		for rows.Next() {
			var c redemptionCodeJSON
			var usedBy sql.NullInt64
			var usedAt sql.NullString
			if err := rows.Scan(&c.ID, &c.Code, &c.DurationDays, &usedBy, &usedAt, &c.CreatedAt, &c.UsedByUsername); err != nil {
				log.Printf("scan redemption code: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			c.UsedBy = nullableInt64(usedBy)
			c.UsedAt = nullableStr(usedAt)
			codes = append(codes, c)
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": codes, "total": total, "page": page})
	}
}

// handleCreateRedemptionCodes: POST /api/v1/admin/redemption-codes {count, duration_days} -> 201 {codes}
func handleCreateRedemptionCodes(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		actor := r.Context().Value(ctxUserIDKey).(int64)
		var req struct {
			Count        int `json:"count"`
			DurationDays int `json:"duration_days"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if req.Count < 1 || req.Count > 100 {
			writeError(w, http.StatusBadRequest, "数量须在 1-100 之间")
			return
		}
		if req.DurationDays < 1 || req.DurationDays > 3650 {
			writeError(w, http.StatusBadRequest, "时长须在 1-3650 天之间")
			return
		}
		tx, err := db.Begin()
		if err != nil {
			log.Printf("begin gen codes: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		codes := make([]string, 0, req.Count)
		for i := 0; i < req.Count; i++ {
			code := genRedemptionCode()
			if _, err := tx.Exec(`INSERT INTO redemption_codes (code, duration_days, created_by) VALUES (?, ?, ?)`,
				code, req.DurationDays, actor); err != nil {
				tx.Rollback()
				log.Printf("insert redemption code: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			codes = append(codes, code)
		}
		if err := tx.Commit(); err != nil {
			log.Printf("commit gen codes: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		logAudit(db, actor, "生成兑换码", map[string]any{"count": req.Count, "duration_days": req.DurationDays})
		writeJSON(w, http.StatusCreated, map[string]any{"codes": codes})
	}
}

// handleDeleteRedemptionCode: DELETE /api/v1/admin/redemption-codes/{id} -> 204
// 仅未使用的兑换码可删除。
func handleDeleteRedemptionCode(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := pathID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的兑换码 ID")
			return
		}
		actor := r.Context().Value(ctxUserIDKey).(int64)
		var usedAt sql.NullString
		err = db.QueryRow(`SELECT used_at FROM redemption_codes WHERE id = ?`, id).Scan(&usedAt)
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, "兑换码不存在")
			return
		}
		if err != nil {
			log.Printf("query redemption code: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if usedAt.Valid && usedAt.String != "" {
			writeError(w, http.StatusBadRequest, "已被使用不可删除")
			return
		}
		if _, err := db.Exec(`DELETE FROM redemption_codes WHERE id = ?`, id); err != nil {
			log.Printf("delete redemption code: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		auditAdmin(db, actor, "删除兑换码", fmt.Sprintf("id:%d", id))
		w.WriteHeader(http.StatusNoContent)
	}
}