package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// loginAdmin bootstraps an admin via ensureAdmin (ADMIN_* env) and logs in.
func loginAdmin(t *testing.T, ts *httptest.Server, db *sql.DB, username, password string) (token string, id int64) {
	t.Helper()
	t.Setenv("ADMIN_USERNAME", username)
	t.Setenv("ADMIN_PASSWORD", password)
	ensureAdmin(db)
	rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/login",
		fmt.Sprintf(`{"username":%q,"password":%q}`, username, password), "")
	if rr.Code != http.StatusOK {
		t.Fatalf("admin login: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		Token string `json:"token"`
		User  struct {
			ID   int64  `json:"id"`
			Role string `json:"role"`
		} `json:"user"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse admin login: %v", err)
	}
	if resp.User.Role != "admin" {
		t.Fatalf("expected admin role, got %q", resp.User.Role)
	}
	return resp.Token, resp.User.ID
}

// findUserID looks up a user by username via the admin list endpoint.
func findUserID(t *testing.T, ts *httptest.Server, tok, username string) int64 {
	t.Helper()
	rr := doReq(t, ts, http.MethodGet, "/api/v1/admin/users?q="+username, "", tok)
	if rr.Code != http.StatusOK {
		t.Fatalf("admin list users: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		Users []struct {
			ID       int64  `json:"id"`
			Username string `json:"username"`
			Tier     string `json:"tier"`
			Role     string `json:"role"`
			Disabled bool   `json:"disabled"`
		} `json:"users"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse user list: %v", err)
	}
	for _, u := range resp.Users {
		if u.Username == username {
			return u.ID
		}
	}
	t.Fatalf("user %q not found in admin list", username)
	return 0
}

func TestAdminRoleEnforcement(t *testing.T) {
	ts, _ := newTestServer(t)
	// missing token -> 401
	rr := doReq(t, ts, http.MethodGet, "/api/v1/admin/stats", "", "")
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("no token: want 401, got %d", rr.Code)
	}
	// normal user -> 403
	userTok := registerUser(t, ts, "alice")
	rr = doReq(t, ts, http.MethodGet, "/api/v1/admin/stats", "", userTok)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("normal user: want 403, got %d body=%s", rr.Code, rr.Body.String())
	}
}

func TestAdminStatsAndUserUpdate(t *testing.T) {
	ts, db := newTestServer(t)
	registerUser(t, ts, "alice")
	registerUser(t, ts, "bob")
	admTok, _ := loginAdmin(t, ts, db, "root", "adminpass123")

	rr := doReq(t, ts, http.MethodGet, "/api/v1/admin/stats", "", admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("stats: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var stats map[string]int
	if err := json.Unmarshal(rr.Body.Bytes(), &stats); err != nil {
		t.Fatalf("parse stats: %v", err)
	}
	if stats["users"] < 3 || stats["assets"] != 0 {
		t.Fatalf("unexpected stats: %+v", stats)
	}

	bobID := findUserID(t, ts, admTok, "bob")
	rr = doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/admin/users/%d", bobID),
		`{"tier":"member","role":"admin"}`, admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("update bob: status=%d body=%s", rr.Code, rr.Body.String())
	}
	rr = doReq(t, ts, http.MethodGet, "/api/v1/admin/users?q=bob", "", admTok)
	var resp struct {
		Users []struct {
			Tier string `json:"tier"`
			Role string `json:"role"`
		} `json:"users"`
	}
	json.Unmarshal(rr.Body.Bytes(), &resp)
	if len(resp.Users) != 1 || resp.Users[0].Tier != "member" || resp.Users[0].Role != "admin" {
		t.Fatalf("bob not updated: %+v", resp.Users)
	}
}

func TestAdminSelfGuards(t *testing.T) {
	ts, db := newTestServer(t)
	admTok, admID := loginAdmin(t, ts, db, "root", "adminpass123")

	for _, body := range []string{`{"role":"user"}`, `{"disabled":true}`} {
		rr := doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/admin/users/%d", admID), body, admTok)
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("self %s: want 400, got %d body=%s", body, rr.Code, rr.Body.String())
		}
	}
	rr := doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/admin/users/%d", admID), "", admTok)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("delete self: want 400, got %d", rr.Code)
	}
}

func TestAdminDisableBlocksAccess(t *testing.T) {
	ts, db := newTestServer(t)
	userTok := registerUser(t, ts, "alice")
	admTok, _ := loginAdmin(t, ts, db, "root", "adminpass123")
	aliceID := findUserID(t, ts, admTok, "alice")

	rr := doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/admin/users/%d", aliceID),
		`{"disabled":true}`, admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("disable: status=%d body=%s", rr.Code, rr.Body.String())
	}
	// existing token blocked
	rr = doReq(t, ts, http.MethodGet, "/api/v1/me", "", userTok)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("disabled token: want 403, got %d", rr.Code)
	}
	// fresh login blocked
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/login",
		`{"username":"alice","password":"password123"}`, "")
	if rr.Code != http.StatusForbidden {
		t.Fatalf("disabled login: want 403, got %d", rr.Code)
	}
	// re-enable restores access
	rr = doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/admin/users/%d", aliceID),
		`{"disabled":false}`, admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("re-enable: status=%d", rr.Code)
	}
	rr = doReq(t, ts, http.MethodGet, "/api/v1/me", "", userTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("re-enabled token: want 200, got %d", rr.Code)
	}
}

func TestAdminDeleteUser(t *testing.T) {
	ts, db := newTestServer(t)
	registerUser(t, ts, "alice")
	admTok, _ := loginAdmin(t, ts, db, "root", "adminpass123")
	aliceID := findUserID(t, ts, admTok, "alice")

	rr := doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/admin/users/%d", aliceID), "", admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("delete alice: status=%d body=%s", rr.Code, rr.Body.String())
	}
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/login",
		`{"username":"alice","password":"password123"}`, "")
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("deleted user login: want 401, got %d", rr.Code)
	}
	// deleting a missing user -> 404
	rr = doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/admin/users/%d", aliceID), "", admTok)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("delete missing: want 404, got %d", rr.Code)
	}
}

func TestAdminBootstrapPromotesExisting(t *testing.T) {
	ts, db := newTestServer(t)
	registerUser(t, ts, "root") // existing user, not admin
	t.Setenv("ADMIN_USERNAME", "root")
	t.Setenv("ADMIN_PASSWORD", "adminpass123")
	ensureAdmin(db)
	rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/login",
		`{"username":"root","password":"password123"}`, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("promoted admin login: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		User struct {
			Role string `json:"role"`
		} `json:"user"`
	}
	json.Unmarshal(rr.Body.Bytes(), &resp)
	if resp.User.Role != "admin" {
		t.Fatalf("expected promotion to admin, got %q", resp.User.Role)
	}
}

func TestAdminConfigRoundTrip(t *testing.T) {
	ts, db := newTestServer(t)
	// Point configFile at a temp path so the repo stays untouched.
	old := configFile
	configFile = filepath.Join(t.TempDir(), "config.json")
	t.Cleanup(func() {
		configFile = old
		systemServers = nil
		freeAssetQuota = 50
	})
	admTok, _ := loginAdmin(t, ts, db, "root", "adminpass123")

	rr := doReq(t, ts, http.MethodPut, "/api/v1/admin/config",
		`{"smtp_servers":[{"host":"smtp.test","port":587,"user":"mailer","password":"secret","from_addr":"a@b.c"}],"free_asset_quota":42}`,
		admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("put config: status=%d body=%s", rr.Code, rr.Body.String())
	}
	rr = doReq(t, ts, http.MethodGet, "/api/v1/admin/config", "", admTok)
	var cfg struct {
		SMTPServers []struct {
			Host        string `json:"host"`
			PasswordSet bool   `json:"password_set"`
		} `json:"smtp_servers"`
		FreeAssetQuota int `json:"free_asset_quota"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &cfg); err != nil {
		t.Fatalf("parse config: %v", err)
	}
	if cfg.FreeAssetQuota != 42 || len(cfg.SMTPServers) != 1 || !cfg.SMTPServers[0].PasswordSet {
		t.Fatalf("unexpected config: %+v", cfg)
	}
	// GET never leaks the password itself
	if contains := jsonContains(rr.Body.String(), "secret"); contains {
		t.Fatal("config GET leaked the SMTP password")
	}

	// Re-PUT with blank password keeps the stored secret.
	rr = doReq(t, ts, http.MethodPut, "/api/v1/admin/config",
		`{"smtp_servers":[{"host":"smtp.test","port":587,"user":"mailer","password":"","from_addr":"a@b.c"}],"free_asset_quota":42}`,
		admTok)
	if rr.Code != http.StatusOK {
		t.Fatalf("put config 2: status=%d body=%s", rr.Code, rr.Body.String())
	}
	data, err := os.ReadFile(configFile)
	if err != nil {
		t.Fatalf("read config file: %v", err)
	}
	if !jsonContains(string(data), "secret") {
		t.Fatal("config.json lost the preserved password")
	}
}

func TestAdminPageServed(t *testing.T) {
	ts, _ := newTestServer(t)
	rr := doReqRaw(t, ts, http.MethodGet, "/admin", "", "")
	if rr.Code != http.StatusOK {
		t.Fatalf("GET /admin: status=%d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "管理后台") || !strings.Contains(body, "<script>") {
		t.Fatal("admin page missing expected content")
	}
}

func jsonContains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// TestAdminLoginLock:管理员连续 5 次密码错误后锁定(429),正确密码也被拒;
// 普通用户不启用锁定。
func TestAdminLoginLock(t *testing.T) {
	ts, db := newTestServer(t)
	t.Setenv("ADMIN_USERNAME", "root")
	t.Setenv("ADMIN_PASSWORD", "adminpass123")
	ensureAdmin(db)

	// 5 次错误密码 -> 第 5 次后锁定。
	for i := 0; i < 5; i++ {
		rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/login",
			`{"username":"root","password":"wrongpass"}`, "")
		if rr.Code != http.StatusUnauthorized {
			t.Fatalf("wrong pass #%d: status=%d want 401", i+1, rr.Code)
		}
	}
	// 锁定后即使密码正确也 429。
	rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/login",
		`{"username":"root","password":"adminpass123"}`, "")
	if rr.Code != http.StatusTooManyRequests {
		t.Fatalf("locked admin login: status=%d want 429 body=%s", rr.Code, rr.Body.String())
	}
	// 普通用户不受影响:注册新用户,5 次错误密码后仍可正常登录。
	token := registerUser(t, ts, "lockuser")
	_ = token
	for i := 0; i < 5; i++ {
		rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/login",
			`{"username":"lockuser","password":"wrongpass"}`, "")
		if rr.Code != http.StatusUnauthorized {
			t.Fatalf("normal user wrong pass #%d: status=%d want 401", i+1, rr.Code)
		}
	}
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/login",
		`{"username":"lockuser","password":"password123"}`, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("normal user login after 5 fails: status=%d want 200 body=%s", rr.Code, rr.Body.String())
	}
}
