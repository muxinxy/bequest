package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"testing"
)

// TestChangePasswordInvalidatesTokens: 改密后旧 token 立即失效,新密码可登录。
func TestChangePasswordInvalidatesTokens(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")

	// 改密(当前密码正确)
	rr := doReq(t, ts, http.MethodPut, "/api/v1/me/password",
		`{"password":"password123","new_password":"newpass456"}`, token)
	if rr.Code != http.StatusOK {
		t.Fatalf("change password: status=%d body=%s", rr.Code, rr.Body.String())
	}
	// 旧 token 立即失效
	rr = doReq(t, ts, http.MethodGet, "/api/v1/me", "", token)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("old token after change: want 401, got %d", rr.Code)
	}
	// 当前密码错误 → 401
	token2 := registerUser(t, ts, "bob")
	rr = doReq(t, ts, http.MethodPut, "/api/v1/me/password",
		`{"password":"wrong-pass","new_password":"newpass456"}`, token2)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("wrong current password: want 401, got %d", rr.Code)
	}
	// 新密码可登录
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/login",
		`{"username":"alice","password":"newpass456"}`, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("login with new password: status=%d body=%s", rr.Code, rr.Body.String())
	}
}

// TestPasswordResetFlow: 邮箱验证码重置 + 尝试次数上限。
func TestPasswordResetFlow(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice") // email = alice@example.com

	insertCode := func(code string) int64 {
		t.Helper()
		h := sha256.Sum256([]byte(code))
		res, err := db.Exec(`INSERT INTO password_resets (user_id, code_hash, expires_at) VALUES (?, ?, datetime('now','+10 minutes'))`,
			userIDOf(t, ts, token), hex.EncodeToString(h[:]))
		if err != nil {
			t.Fatalf("insert reset code: %v", err)
		}
		id, _ := res.LastInsertId()
		return id
	}

	// 正确码重置成功
	insertCode("123456")
	rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/reset",
		`{"email":"alice@example.com","code":"123456","new_password":"resetpass1"}`, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("reset with correct code: status=%d body=%s", rr.Code, rr.Body.String())
	}
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/login",
		`{"username":"alice","password":"resetpass1"}`, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("login after reset: status=%d", rr.Code)
	}

	// 5 次错误码 → 作废
	insertCode("654321")
	for i := 0; i < 5; i++ {
		rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/reset",
			fmt.Sprintf(`{"email":"alice@example.com","code":"%06d","new_password":"xpass1234"}`, i+1), "")
		if rr.Code != http.StatusUnauthorized {
			t.Fatalf("wrong code attempt %d: want 401, got %d", i, rr.Code)
		}
	}
	// 第 6 次(即使用正确码)也拒绝——码已作废
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/reset",
		`{"email":"alice@example.com","code":"654321","new_password":"xpass1234"}`, "")
	if rr.Code != http.StatusUnauthorized && rr.Code != http.StatusTooManyRequests {
		t.Fatalf("exhausted code: want 401/429, got %d", rr.Code)
	}
}
