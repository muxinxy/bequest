package main

import (
	"context"
	"net/http"
	"strings"
)

type ctxKey int

const ctxUserIDKey ctxKey = 0

// requireAuth enforces a valid Bearer token, placing user_id into the request context.
func requireAuth(next http.Handler) http.Handler {
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
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxUserIDKey, uid)))
	})
}
