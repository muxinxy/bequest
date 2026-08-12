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
// placing user_id into the request context.
func requireAuth(db *sql.DB, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			writeError(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		uid, err := verifyToken(strings.TrimPrefix(auth, "Bearer "))
		if err != nil {
			writeError(w, http.StatusUnauthorized, "invalid or expired token")
			return
		}
		var disabled int
		if err := db.QueryRow(`SELECT disabled FROM users WHERE id = ?`, uid).Scan(&disabled); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusUnauthorized, "user no longer exists")
				return
			}
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if disabled == 1 {
			writeError(w, http.StatusForbidden, "账号已被禁用")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxUserIDKey, uid)))
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
