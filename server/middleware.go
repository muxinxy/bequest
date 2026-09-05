package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"strings"
)

type ctxKey int

const ctxUserIDKey ctxKey = 0

// requireAuth enforces a valid Bearer token and a non-disabled account,
// placing user_id into the request context. 2FA pending tokens are rejected
// (they exist only for the /auth/2fa/verify step, never as a session).
func requireAuth(db *sql.DB, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			writeError(w, http.StatusUnauthorized, "缺少 Bearer 令牌")
			return
		}
		c, err := verifyToken(strings.TrimPrefix(auth, "Bearer "))
		if err != nil || c.Pending2FA {
			writeError(w, http.StatusUnauthorized, "无效或已过期的令牌")
			return
		}
		var disabled, tokenVersion int
		if err := db.QueryRow(`SELECT disabled, token_version FROM users WHERE id = ?`, c.UserID).Scan(&disabled, &tokenVersion); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusUnauthorized, "用户已不存在")
				return
			}
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if c.TokenVersion != tokenVersion {
			// 改密后旧 token 失效。
			writeError(w, http.StatusUnauthorized, "无效或已过期的令牌")
			return
		}
		if disabled == 1 {
			writeError(w, http.StatusForbidden, "账号已被禁用")
			return
		}
		// 活跃心跳:已认证请求周期性刷新 last_login_at,避免活跃用户被误判失联。
		touchLastLogin(db, c.UserID)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxUserIDKey, c.UserID)))
	})
}

// touchLastLogin 活跃心跳:距上次登录超过 12 小时才写库(带时间门槛,避免每次
// 请求都 UPDATE)。只刷新 last_login_at,不重置 inherit_stage/escalation_level
// —— 只有登录才重置那些(见 auth.go 登录成功逻辑)。
func touchLastLogin(db *sql.DB, uid int64) {
	if _, err := db.Exec(`UPDATE users SET last_login_at = `+dbNow()+`
		WHERE id = ? AND (last_login_at IS NULL OR last_login_at < `+dbNowAdd("-12 hours")+`)`, uid); err != nil {
		log.Printf("touch last_login: %v", err)
	}
}

// cors enables browser access from other origins (Flutter dev server, separate
// web hosting). Auth is a Bearer header, not cookies, so * is acceptable.
// Same-origin (server-hosted web build) is unaffected.
func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
