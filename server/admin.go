package main

import (
	"context"
	"database/sql"
	"embed"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

//go:embed admin.html claim.html
var adminFS embed.FS

// serveClaimPage: GET /claim -> 继承人交接领取页(无鉴权,领取校验在 API)。
func serveClaimPage(w http.ResponseWriter, r *http.Request) {
	page, err := adminFS.ReadFile("claim.html")
	if err != nil {
		writeError(w, http.StatusInternalServerError, "claim page missing")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(page)
}

// ---------- bootstrap ----------

// ensureAdmin creates (or promotes) the admin account from ADMIN_USERNAME /
// ADMIN_PASSWORD at startup. Existing user -> only role='admin' is ensured
// (password stays operator-managed); missing user -> created as admin.
func ensureAdmin(db *sql.DB) {
	user := os.Getenv("ADMIN_USERNAME")
	if user == "" {
		return
	}
	var id int64
	err := db.QueryRow(`SELECT id FROM users WHERE username = ?`, user).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		pass := os.Getenv("ADMIN_PASSWORD")
		if pass == "" {
			log.Printf("ADMIN_USERNAME set but ADMIN_PASSWORD missing; skipping admin bootstrap")
			return
		}
		hash, herr := hashPassword(pass)
		if herr != nil {
			log.Printf("bootstrap admin: %v", herr)
			return
		}
		if _, ierr := db.Exec(`INSERT INTO users (username, email, password_hash, role) VALUES (?, ?, ?, 'admin')`,
			user, user+"@admin.local", hash); ierr != nil {
			log.Printf("bootstrap admin insert: %v", ierr)
			return
		}
		log.Printf("admin user %q created", user)
		return
	}
	if err != nil {
		log.Printf("bootstrap admin query: %v", err)
		return
	}
	if _, err := db.Exec(`UPDATE users SET role = 'admin' WHERE id = ?`, id); err != nil {
		log.Printf("bootstrap admin promote: %v", err)
		return
	}
	log.Printf("user %q promoted to admin", user)
}

// ---------- admin auth ----------

// requireAdmin enforces a Bearer token whose user has role='admin' and is not
// disabled. Role is read from the DB on every request so promotions/demotions
// take effect immediately (no stale JWT claim).
func requireAdmin(db *sql.DB, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			writeError(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		c, err := verifyToken(strings.TrimPrefix(auth, "Bearer "))
		if err != nil || c.Pending2FA {
			writeError(w, http.StatusUnauthorized, "invalid or expired token")
			return
		}
		var role string
		var disabled, tokenVersion int
		if err := db.QueryRow(`SELECT role, disabled, token_version FROM users WHERE id = ?`, c.UserID).Scan(&role, &disabled, &tokenVersion); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusUnauthorized, "user no longer exists")
				return
			}
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if c.TokenVersion != tokenVersion {
			writeError(w, http.StatusUnauthorized, "invalid or expired token")
			return
		}
		if disabled == 1 {
			writeError(w, http.StatusForbidden, "账号已被禁用")
			return
		}
		if role != "admin" {
			writeError(w, http.StatusForbidden, "admin required")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxUserIDKey, c.UserID)))
	})
}

// auditAdmin records an admin action for the trust log.
func auditAdmin(db *sql.DB, uid int64, action, detail string) {
	if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (?, 'admin', ?, ?)`,
		uid, action, detail); err != nil {
		log.Printf("audit admin %s: %v", action, err)
	}
}

func pathID(r *http.Request) (int64, error) {
	return strconv.ParseInt(r.PathValue("id"), 10, 64)
}

func atoiDefault(s string, def int) int {
	if n, err := strconv.Atoi(s); err == nil && n > 0 {
		return n
	}
	return def
}

// ---------- dashboard ----------

// handleAdminStats: GET /api/v1/admin/stats -> {users, members, ...}
func handleAdminStats(db *sql.DB) http.HandlerFunc {
	queries := map[string]string{
		"users":                      "SELECT COUNT(*) FROM users",
		"members":                    "SELECT COUNT(*) FROM users WHERE tier = 'member'",
		"admins":                     "SELECT COUNT(*) FROM users WHERE role = 'admin'",
		"disabled_users":             "SELECT COUNT(*) FROM users WHERE disabled = 1",
		"assets":                     "SELECT COUNT(*) FROM assets",
		"categories":                 "SELECT COUNT(*) FROM categories",
		"inheritors":                 "SELECT COUNT(*) FROM inheritors",
		"pending_inheritance_events": "SELECT COUNT(*) FROM inheritance_events WHERE status IN ('pending','claimed')",
		"unread_reminders":           "SELECT COUNT(*) FROM reminders WHERE status = 'pending'",
	}
	return func(w http.ResponseWriter, r *http.Request) {
		stats := make(map[string]int, len(queries))
		for k, q := range queries {
			var n int
			if err := db.QueryRow(q).Scan(&n); err == nil {
				stats[k] = n
			}
		}
		writeJSON(w, http.StatusOK, stats)
	}
}

// ---------- users ----------

type adminUser struct {
	ID             int64  `json:"id"`
	Username       string `json:"username"`
	Email          string `json:"email"`
	Tier           string `json:"tier"`
	Role           string `json:"role"`
	Disabled       bool   `json:"disabled"`
	InheritStage   string `json:"inherit_stage"`
	LastLoginAt    string `json:"last_login_at"`
	CreatedAt      string `json:"created_at"`
	AssetCount     int    `json:"asset_count"`
	InheritorCount int    `json:"inheritor_count"`
}

// handleAdminListUsers: GET /api/v1/admin/users?q=&role=&tier=&page=&page_size=
func handleAdminListUsers(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		q := strings.TrimSpace(r.URL.Query().Get("q"))
		role := r.URL.Query().Get("role")
		tier := r.URL.Query().Get("tier")
		page := atoiDefault(r.URL.Query().Get("page"), 1)
		pageSize := atoiDefault(r.URL.Query().Get("page_size"), 20)
		if pageSize > 100 {
			pageSize = 100
		}
		where := []string{"1=1"}
		args := []any{}
		if q != "" {
			where = append(where, "(username LIKE ? OR email LIKE ?)")
			args = append(args, "%"+q+"%", "%"+q+"%")
		}
		if role != "" {
			where = append(where, "role = ?")
			args = append(args, role)
		}
		if tier != "" {
			where = append(where, "tier = ?")
			args = append(args, tier)
		}
		cond := strings.Join(where, " AND ")

		var total int
		if err := db.QueryRow(`SELECT COUNT(*) FROM users WHERE `+cond, args...).Scan(&total); err != nil {
			log.Printf("admin count users: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		args = append(args, pageSize, (page-1)*pageSize)
		rows, err := db.Query(`SELECT u.id, u.username, u.email, u.tier, u.role, u.disabled,
				u.inherit_stage, u.last_login_at, u.created_at,
				(SELECT COUNT(*) FROM assets a WHERE a.user_id = u.id),
				(SELECT COUNT(*) FROM inheritors i WHERE i.user_id = u.id)
			FROM users u WHERE `+cond+` ORDER BY u.id DESC LIMIT ? OFFSET ?`, args...)
		if err != nil {
			log.Printf("admin list users: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		users := []adminUser{}
		for rows.Next() {
			var u adminUser
			var disabled int
			var lastLogin sql.NullString
			if err := rows.Scan(&u.ID, &u.Username, &u.Email, &u.Tier, &u.Role, &disabled,
				&u.InheritStage, &lastLogin, &u.CreatedAt, &u.AssetCount, &u.InheritorCount); err != nil {
				log.Printf("admin scan user: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			u.Disabled = disabled == 1
			u.LastLoginAt = lastLogin.String
			users = append(users, u)
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"total": total, "page": page, "page_size": pageSize, "users": users,
		})
	}
}

// handleAdminGetUser: GET /api/v1/admin/users/{id} -> detail incl. audit trail
func handleAdminGetUser(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := pathID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid user id")
			return
		}
		var u adminUser
		var disabled int
		var lastLogin sql.NullString
		err = db.QueryRow(`SELECT u.id, u.username, u.email, u.tier, u.role, u.disabled,
				u.inherit_stage, u.last_login_at, u.created_at,
				(SELECT COUNT(*) FROM assets a WHERE a.user_id = u.id),
				(SELECT COUNT(*) FROM inheritors i WHERE i.user_id = u.id)
			FROM users u WHERE u.id = ?`, id).
			Scan(&u.ID, &u.Username, &u.Email, &u.Tier, &u.Role, &disabled,
				&u.InheritStage, &lastLogin, &u.CreatedAt, &u.AssetCount, &u.InheritorCount)
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, "user not found")
			return
		}
		if err != nil {
			log.Printf("admin get user: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		u.Disabled = disabled == 1
		u.LastLoginAt = lastLogin.String
		writeJSON(w, http.StatusOK, u)
	}
}

type adminUserUpdate struct {
	Role     *string `json:"role"`
	Tier     *string `json:"tier"`
	Disabled *bool   `json:"disabled"`
}

// handleAdminUpdateUser: PUT /api/v1/admin/users/{id} -> {role?, tier?, disabled?}
func handleAdminUpdateUser(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := pathID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid user id")
			return
		}
		actor := r.Context().Value(ctxUserIDKey).(int64)
		var req adminUserUpdate
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		// An admin must never lock themselves out: no self-demotion/disable.
		if id == actor {
			if (req.Role != nil && *req.Role != "admin") || (req.Disabled != nil && *req.Disabled) {
				writeError(w, http.StatusBadRequest, "cannot demote or disable yourself")
				return
			}
		}
		sets := []string{}
		args := []any{}
		if req.Role != nil {
			if *req.Role != "user" && *req.Role != "admin" {
				writeError(w, http.StatusBadRequest, "role must be user or admin")
				return
			}
			sets = append(sets, "role = ?")
			args = append(args, *req.Role)
		}
		if req.Tier != nil {
			if *req.Tier != "free" && *req.Tier != "member" {
				writeError(w, http.StatusBadRequest, "tier must be free or member")
				return
			}
			sets = append(sets, "tier = ?")
			args = append(args, *req.Tier)
		}
		if req.Disabled != nil {
			d := 0
			if *req.Disabled {
				d = 1
			}
			sets = append(sets, "disabled = ?")
			args = append(args, d)
		}
		if len(sets) == 0 {
			writeError(w, http.StatusBadRequest, "nothing to update")
			return
		}
		sets = append(sets, "updated_at = datetime('now')")
		args = append(args, id)
		res, err := db.Exec(`UPDATE users SET `+strings.Join(sets, ", ")+` WHERE id = ?`, args...)
		if err != nil {
			log.Printf("admin update user: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "user not found")
			return
		}
		auditAdmin(db, actor, "admin_user_update", fmt.Sprintf("user_id:%d", id))
		writeJSON(w, http.StatusOK, map[string]string{"ok": "true"})
	}
}

// handleAdminDeleteUser: DELETE /api/v1/admin/users/{id} (cascades assets etc.)
func handleAdminDeleteUser(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := pathID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid user id")
			return
		}
		actor := r.Context().Value(ctxUserIDKey).(int64)
		if id == actor {
			writeError(w, http.StatusBadRequest, "cannot delete yourself")
			return
		}
		res, err := db.Exec(`DELETE FROM users WHERE id = ?`, id)
		if err != nil {
			log.Printf("admin delete user: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "user not found")
			return
		}
		auditAdmin(db, actor, "admin_user_delete", fmt.Sprintf("user_id:%d", id))
		writeJSON(w, http.StatusOK, map[string]string{"ok": "true"})
	}
}

// ---------- audit log ----------

// handleAdminAuditLog: GET /api/v1/admin/audit-log?user_id=&page=&page_size=
func handleAdminAuditLog(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		page := atoiDefault(r.URL.Query().Get("page"), 1)
		pageSize := atoiDefault(r.URL.Query().Get("page_size"), 50)
		if pageSize > 200 {
			pageSize = 200
		}
		cond := "1=1"
		args := []any{}
		if uid := strings.TrimSpace(r.URL.Query().Get("user_id")); uid != "" {
			cond = "user_id = ?"
			args = append(args, uid)
		}
		var total int
		if err := db.QueryRow(`SELECT COUNT(*) FROM audit_logs WHERE `+cond, args...).Scan(&total); err != nil {
			log.Printf("admin count audit: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		args = append(args, pageSize, (page-1)*pageSize)
		rows, err := db.Query(`SELECT id, user_id, actor, action, detail, created_at
			FROM audit_logs WHERE `+cond+` ORDER BY id DESC LIMIT ? OFFSET ?`, args...)
		if err != nil {
			log.Printf("admin list audit: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		type entry struct {
			ID        int64  `json:"id"`
			UserID    int64  `json:"user_id"`
			Actor     string `json:"actor"`
			Action    string `json:"action"`
			Detail    string `json:"detail"`
			CreatedAt string `json:"created_at"`
		}
		entries := []entry{}
		for rows.Next() {
			var e entry
			if err := rows.Scan(&e.ID, &e.UserID, &e.Actor, &e.Action, &e.Detail, &e.CreatedAt); err != nil {
				log.Printf("admin scan audit: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			entries = append(entries, e)
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"total": total, "page": page, "page_size": pageSize, "entries": entries,
		})
	}
}

// ---------- 2FA (TOTP) ----------

// handleAdmin2FAStatus: GET /api/v1/admin/2fa -> {enabled}
func handleAdmin2FAStatus(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var secret string
		db.QueryRow(`SELECT totp_secret FROM users WHERE id = ?`, uid).Scan(&secret)
		writeJSON(w, http.StatusOK, map[string]any{"enabled": secret != ""})
	}
}

// handleAdmin2FASetup: POST /api/v1/admin/2fa/setup -> {secret, otpauth_uri}
// 密钥仅返回给客户端(未落库);用确认接口校验通过后才启用。
func handleAdmin2FASetup(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var username string
		if err := db.QueryRow(`SELECT username FROM users WHERE id = ?`, uid).Scan(&username); err != nil {
			username = "admin"
		}
		secret, err := generateTOTPSecret()
		if err != nil {
			log.Printf("gen totp secret: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		uri := fmt.Sprintf("otpauth://totp/bequest:%s?secret=%s&issuer=bequest&digits=6&period=30", username, secret)
		writeJSON(w, http.StatusOK, map[string]any{"secret": secret, "otpauth_uri": uri})
	}
}

// handleAdmin2FAConfirm: POST /api/v1/admin/2fa/confirm {secret, code} -> 启用
func handleAdmin2FAConfirm(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req struct {
			Secret string `json:"secret"`
			Code   string `json:"code"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		if !verifyTOTP(req.Secret, strings.TrimSpace(req.Code), time.Now()) {
			writeError(w, http.StatusBadRequest, "验证码错误")
			return
		}
		if _, err := db.Exec(`UPDATE users SET totp_secret = ?, updated_at = datetime('now') WHERE id = ?`,
			req.Secret, uid); err != nil {
			log.Printf("enable 2fa: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		auditAdmin(db, uid, "admin_2fa_enabled", "")
		writeJSON(w, http.StatusOK, map[string]string{"ok": "true"})
	}
}

// handleAdmin2FADisable: POST /api/v1/admin/2fa/disable {code} -> 停用
func handleAdmin2FADisable(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req struct {
			Code string `json:"code"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		var secret string
		if err := db.QueryRow(`SELECT totp_secret FROM users WHERE id = ?`, uid).Scan(&secret); err != nil || secret == "" {
			writeError(w, http.StatusBadRequest, "2FA 未启用")
			return
		}
		if !verifyTOTP(secret, strings.TrimSpace(req.Code), time.Now()) {
			writeError(w, http.StatusUnauthorized, "验证码错误")
			return
		}
		if _, err := db.Exec(`UPDATE users SET totp_secret = NULL, updated_at = datetime('now') WHERE id = ?`, uid); err != nil {
			log.Printf("disable 2fa: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		auditAdmin(db, uid, "admin_2fa_disabled", "")
		writeJSON(w, http.StatusOK, map[string]string{"ok": "true"})
	}
}

// ---------- 用户资产明细 ----------

// handleAdminListUserAssets: GET /api/v1/admin/users/{id}/assets ->
// 该用户的资产元数据清单(不含密文与密钥包装,服务端本就不见明文)。
func handleAdminListUserAssets(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := pathID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid user id")
			return
		}
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM users WHERE id = ?`, id).Scan(&n); err != nil || n == 0 {
			writeError(w, http.StatusNotFound, "user not found")
			return
		}
		rows, err := db.Query(`SELECT a.id, a.name, a.asset_type, a.expiry_date, a.created_at, a.updated_at, COALESCE(c.name, '')
			FROM assets a LEFT JOIN categories c ON c.id = a.category_id
			WHERE a.user_id = ? ORDER BY a.id DESC`, id)
		if err != nil {
			log.Printf("admin list user assets: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		type assetMeta struct {
			ID         int64   `json:"id"`
			Name       string  `json:"name"`
			AssetType  string  `json:"asset_type"`
			Category   string  `json:"category"`
			ExpiryDate *string `json:"expiry_date"`
			CreatedAt  string  `json:"created_at"`
			UpdatedAt  string  `json:"updated_at"`
		}
		list := []assetMeta{}
		for rows.Next() {
			var a assetMeta
			var cat sql.NullString
			var expiry sql.NullString
			if err := rows.Scan(&a.ID, &a.Name, &a.AssetType, &expiry, &a.CreatedAt, &a.UpdatedAt, &cat); err != nil {
				log.Printf("admin scan user asset: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			a.Category = cat.String
			if expiry.Valid {
				a.ExpiryDate = &expiry.String
			}
			list = append(list, a)
		}
		writeJSON(w, http.StatusOK, map[string]any{"user_id": id, "assets": list})
	}
}

// ---------- 审计日志导出 ----------

// handleAdminAuditExport: GET /api/v1/admin/audit-log/export?user_id=&limit= -> CSV 附件
func handleAdminAuditExport(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		limit := atoiDefault(r.URL.Query().Get("limit"), 10000)
		if limit > 100000 {
			limit = 100000
		}
		cond := "1=1"
		args := []any{}
		if uid := strings.TrimSpace(r.URL.Query().Get("user_id")); uid != "" {
			cond = "user_id = ?"
			args = append(args, uid)
		}
		rows, err := db.Query(`SELECT id, user_id, actor, action, detail, created_at FROM audit_logs
			WHERE `+cond+` ORDER BY id DESC LIMIT ?`, append(args, limit)...)
		if err != nil {
			log.Printf("admin export audit: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		w.Header().Set("Content-Type", "text/csv; charset=utf-8")
		w.Header().Set("Content-Disposition",
			fmt.Sprintf(`attachment; filename="audit-log-%s.csv"`, time.Now().Format("20060102-150405")))
		// UTF-8 BOM:Excel 直接打开不乱码。
		w.Write([]byte{0xEF, 0xBB, 0xBF})
		cw := csv.NewWriter(w)
		cw.Write([]string{"id", "user_id", "actor", "action", "detail", "created_at"})
		for rows.Next() {
			var id, uid int64
			var actor, action, detail, createdAt string
			if err := rows.Scan(&id, &uid, &actor, &action, &detail, &createdAt); err != nil {
				log.Printf("admin scan audit export: %v", err)
				continue
			}
			cw.Write([]string{fmt.Sprint(id), fmt.Sprint(uid), actor, action, detail, createdAt})
		}
		cw.Flush()
	}
}

// ---------- system config ----------

// maskProviders 隐藏密钥,只暴露名称与"是否已配置"。
func maskProviders(ps []provider) []map[string]any {
	out := make([]map[string]any, 0, len(ps))
	for _, p := range ps {
		out = append(out, map[string]any{
			"name":            p.Name,
			"api_key_set":     p.APIKey != "",
			"api_secret_set":  p.APISecret != "",
		})
	}
	return out
}

// handleAdminGetConfig: GET /api/v1/admin/config -> effective system settings
// (SMTP 密码与 provider 密钥均不回显,只给 *_set 标记)。
func handleAdminGetConfig(w http.ResponseWriter, r *http.Request) {
	servers := make([]map[string]any, 0, len(systemServers))
	for _, s := range systemServers {
		servers = append(servers, map[string]any{
			"host":         s.Host,
			"port":         s.Port,
			"user":         s.User,
			"from_addr":    s.FromAddr,
			"password_set": s.Password != "",
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"smtp_servers":     servers,
		"free_asset_quota": freeAssetQuota,
		"sms_providers":    maskProviders(smsProviders),
		"phone_providers":  maskProviders(phoneProviders),
	})
}

type smtpServerInput struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	User     string `json:"user"`
	Password string `json:"password"` // empty on update = keep existing
	FromAddr string `json:"from_addr"`
}

type providerInput struct {
	Name      string `json:"name"`
	APIKey    string `json:"api_key"`    // empty on update = keep existing
	APISecret string `json:"api_secret"` // empty on update = keep existing
}

type adminConfigInput struct {
	SMTPServers    []smtpServerInput `json:"smtp_servers"`
	SMSProviders   []providerInput   `json:"sms_providers"`
	PhoneProviders []providerInput   `json:"phone_providers"`
	FreeAssetQuota int               `json:"free_asset_quota"`
}

// mergeProviders 按名称合并:留空的 key/secret 保留原值。
func mergeProviders(inputs []providerInput, existing []provider) []provider {
	keep := map[string]provider{}
	for _, p := range existing {
		keep[p.Name] = p
	}
	out := make([]provider, 0, len(inputs))
	for _, in := range inputs {
		name := strings.TrimSpace(in.Name)
		if name == "" {
			continue
		}
		key, secret := in.APIKey, in.APISecret
		if prev, ok := keep[name]; ok {
			if key == "" {
				key = prev.APIKey
			}
			if secret == "" {
				secret = prev.APISecret
			}
		}
		out = append(out, provider{Name: name, APIKey: key, APISecret: secret})
	}
	return out
}

// handleAdminPutConfig: PUT /api/v1/admin/config -> persist config.json and
// reload in-memory providers. Blank passwords/keys keep the stored secrets.
func handleAdminPutConfig(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		actor := r.Context().Value(ctxUserIDKey).(int64)
		var req adminConfigInput
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		cfg := readConfigFile()
		existing := map[string]string{}
		for _, s := range cfg.SMTPServers {
			existing[s.Host+"|"+s.User] = s.Password
		}
		servers := make([]smtpServer, 0, len(req.SMTPServers))
		for _, in := range req.SMTPServers {
			if strings.TrimSpace(in.Host) == "" || in.Port <= 0 {
				writeError(w, http.StatusBadRequest, "smtp host and port required")
				return
			}
			pass := in.Password
			if pass == "" {
				pass = existing[in.Host+"|"+in.User]
			}
			servers = append(servers, smtpServer{Host: in.Host, Port: in.Port, User: in.User, Password: pass, FromAddr: in.FromAddr})
		}
		cfg.SMTPServers = servers
		cfg.SMSProviders = mergeProviders(req.SMSProviders, cfg.SMSProviders)
		cfg.PhoneProviders = mergeProviders(req.PhoneProviders, cfg.PhoneProviders)
		if req.FreeAssetQuota > 0 {
			cfg.FreeAssetQuota = req.FreeAssetQuota
		}
		if err := writeConfigFile(cfg); err != nil {
			log.Printf("admin write config: %v", err)
			writeError(w, http.StatusInternalServerError, "cannot write config.json")
			return
		}
		loadConfig() // reload systemServers/freeAssetQuota/providers in memory
		auditAdmin(db, actor, "admin_config_update", fmt.Sprintf("smtp_servers:%d sms:%d phone:%d quota:%d",
			len(servers), len(cfg.SMSProviders), len(cfg.PhoneProviders), freeAssetQuota))
		writeJSON(w, http.StatusOK, map[string]string{"ok": "true"})
	}
}

// serveAdminPage: GET /admin -> embedded single-page admin UI.
func serveAdminPage(w http.ResponseWriter, r *http.Request) {
	page, err := adminFS.ReadFile("admin.html")
	if err != nil {
		writeError(w, http.StatusInternalServerError, "admin page missing")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(page)
}
