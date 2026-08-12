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

// TestRequestPasswordResetEmits: 发送验证码接口——已知邮箱生成验证码(可入库),
// 未知邮箱返回 200 但不发码(防枚举);用户已配置自定义 SMTP 时优先走用户 SMTP
// (sendCustomForUser),不配置时回退系统 SMTP,均不阻断 200。
func TestRequestPasswordResetEmits(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice") // email = alice@example.com
	uid := userIDOf(t, ts, token)

	countCodes := func() int {
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM password_resets WHERE user_id = ?`, uid).Scan(&n); err != nil {
			t.Fatalf("count reset codes: %v", err)
		}
		return n
	}

	// 未知邮箱:200 且不发码(防枚举)。
	rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/reset-request",
		`{"email":"nobody@example.com"}`, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("unknown email: want 200, got %d", rr.Code)
	}

	// 已知邮箱:200 且生成一条验证码。
	if n := countCodes(); n != 0 {
		t.Fatalf("unknown email inserted %d codes, want 0", n)
	}
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/reset-request",
		`{"email":"alice@example.com"}`, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("known email: want 200, got %d body=%s", rr.Code, rr.Body.String())
	}
	if n := countCodes(); n != 1 {
		t.Fatalf("known email inserted %d codes, want 1", n)
	}

	// 用户配置了自定义 SMTP(host 非空)时,仍 200 且发码路径不 panic。
	if _, err := db.Exec(
		`INSERT INTO user_smtp (user_id, host, port, user, password_enc, from_addr, enabled)
		 VALUES (?, 'smtp.test', 587, 'u', x'00', 'a@b.c', 1)`, uid); err != nil {
		t.Fatalf("insert user smtp: %v", err)
	}
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/reset-request",
		`{"email":"alice@example.com"}`, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("known email with custom smtp: want 200, got %d", rr.Code)
	}
	if n := countCodes(); n != 2 {
		t.Fatalf("known email with custom smtp inserted %d codes, want 2", n)
	}
}
