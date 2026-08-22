package main

import (
	"context"
	"database/sql"
	"errors"
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
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxUserIDKey, c.UserID)))
	})
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
