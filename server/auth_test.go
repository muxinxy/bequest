package main

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

// newTestServer builds the full app wiring against a throwaway DB.
// TEST_DB_DRIVER selects the backend: empty/"sqlite" uses a temp file DB;
// "mysql"/"postgres" connect to the live server described by TEST_DB_DSN
// (or the standard DB_HOST/DB_PORT/DB_USER/DB_PASS/DB_NAME envs) and wipe
// + recreate the schema so every run starts clean. Never touches data/.
func newTestServer(t *testing.T) (*httptest.Server, *sql.DB) {
	t.Helper()
	driverName := os.Getenv("TEST_DB_DRIVER")
	if driverName == "" {
		driverName = "sqlite"
	}
	switch driverName {
	case "sqlite":
		dir := t.TempDir()
		db, err := sql.Open("sqlite", "file:"+filepath.Join(dir, "test.db")+
			"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)")
		if err != nil {
			t.Fatalf("open test db: %v", err)
		}
		db.SetMaxOpenConns(1)
		t.Cleanup(func() { db.Close() })
		if err := runMigrations(db); err != nil {
			t.Fatalf("run migrations: %v", err)
		}
		ts := httptest.NewServer(newMux(db))
		t.Cleanup(ts.Close)
		return ts, db
	case "mysql":
		old := currentDialect
		currentDialect = dialectMySQL
		t.Cleanup(func() { currentDialect = old })
		db := openTestMySQL(t)
		if err := dropAllTables(t, db); err != nil {
			t.Fatalf("reset mysql schema: %v", err)
		}
		if err := runMigrations(db); err != nil {
			t.Fatalf("run mysql migrations: %v", err)
		}
		ts := httptest.NewServer(newMux(db))
		t.Cleanup(func() { ts.Close(); db.Close() })
		return ts, db
	case "postgres":
		old := currentDialect
		currentDialect = dialectPostgres
		t.Cleanup(func() { currentDialect = old })
		db := openTestPostgres(t)
		if err := dropAllTables(t, db); err != nil {
			t.Fatalf("reset postgres schema: %v", err)
		}
		if err := runMigrations(db); err != nil {
			t.Fatalf("run postgres migrations: %v", err)
		}
		ts := httptest.NewServer(newMux(db))
		t.Cleanup(func() { ts.Close(); db.Close() })
		return ts, db
	default:
		t.Fatalf("unsupported TEST_DB_DRIVER %q", driverName)
		return nil, nil
	}
}

// openTestMySQL connects to the MySQL/MariaDB test server.
func openTestMySQL(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("TEST_DB_DSN")
	if dsn == "" {
		user := envOr("TEST_DB_USER", "bequest")
		pass := envOr("TEST_DB_PASS", "bequest")
		host := envOr("TEST_DB_HOST", "127.0.0.1")
		port := envOr("TEST_DB_PORT", "3306")
		name := envOr("TEST_DB_NAME", "bequest_test")
		dsn = fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?charset=utf8mb4&collation=utf8mb4_unicode_ci&parseTime=false&clientFoundRows=true",
			user, pass, host, port, name)
	}
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatalf("open mysql: %v", err)
	}
	if err := db.Ping(); err != nil {
		t.Fatalf("ping mysql (is the test server up?): %v", err)
	}
	return db
}

// openTestPostgres connects to the PostgreSQL test server through the pgxrw
// driver so the same '?' rewrite is exercised.
func openTestPostgres(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("TEST_PG_DSN")
	if dsn == "" {
		host := envOr("TEST_PG_HOST", "127.0.0.1")
		port := envOr("TEST_PG_PORT", "5433")
		user := envOr("TEST_PG_USER", "bequest")
		pass := envOr("TEST_PG_PASS", "bequest")
		name := envOr("TEST_PG_NAME", "bequest_test")
		dsn = fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
			host, port, user, pass, name)
	}
	db, err := sql.Open("pgxrw", dsn)
	if err != nil {
		t.Fatalf("open postgres: %v", err)
	}
	if err := db.Ping(); err != nil {
		t.Fatalf("ping postgres (is the test server up?): %v", err)
	}
	return db
}

// dropAllTables removes every table in the public schema so migrations run on
// an empty database.
func dropAllTables(t *testing.T, db *sql.DB) error {
	t.Helper()
	switch currentDialect {
	case dialectMySQL:
		// MySQL/MariaDB: drop everything including FK order via SET FOREIGN_KEY_CHECKS.
		if _, err := db.Exec(`SET FOREIGN_KEY_CHECKS = 0`); err != nil {
			return err
		}
		rows, err := db.Query(`SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()`)
		if err != nil {
			return err
		}
		var tables []string
		for rows.Next() {
			var tn string
			if err := rows.Scan(&tn); err != nil {
				rows.Close()
				return err
			}
			tables = append(tables, tn)
		}
		rows.Close()
		for _, tn := range tables {
			if _, err := db.Exec("DROP TABLE IF EXISTS `" + tn + "`"); err != nil {
				return err
			}
		}
		_, err = db.Exec(`SET FOREIGN_KEY_CHECKS = 1`)
		return err
	case dialectPostgres:
		if _, err := db.Exec(`DROP SCHEMA public CASCADE; CREATE SCHEMA public`); err != nil {
			return err
		}
		return nil
	default:
		return nil
	}
}

// doReq performs a request against the test server through the real HTTP stack.
// 对 /auth/register 与 /auth/login 自动注入验证码(测试便利;生产 handler 校验)。
func doReq(t *testing.T, ts *httptest.Server, method, path, body, token string) *httptest.ResponseRecorder {
	t.Helper()
	if body != "" && (path == "/api/v1/auth/register" || path == "/api/v1/auth/login") {
		var m map[string]any
		if err := json.Unmarshal([]byte(body), &m); err == nil {
			if _, hasID := m["captcha_id"]; !hasID {
				c := fetchCaptcha(t, ts)
				m["captcha_id"] = c["captcha_id"]
				m["captcha"] = c["captcha"]
				out, _ := json.Marshal(m)
				body = string(out)
			}
		}
	}
	req, err := http.NewRequest(method, ts.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer resp.Body.Close()
	rr := httptest.NewRecorder()
	rr.Code = resp.StatusCode
	for k, vv := range resp.Header {
		for _, v := range vv {
			rr.Header().Add(k, v)
		}
	}
	rr.Body.ReadFrom(resp.Body)
	return rr
}

// fetchCaptcha gets a fresh captcha and solves it (test helper).
// 先请求 HTTP 端点确认 SVG 结构,再用内部 generateCaptcha 拿明文答案
// (答案只存哈希,无法从响应取回)。
func fetchCaptcha(t *testing.T, ts *httptest.Server) map[string]string {
	t.Helper()
	rr := doReqRaw(t, ts, http.MethodGet, "/api/v1/auth/captcha", "", "")
	if rr.Code != http.StatusOK {
		t.Fatalf("captcha status = %d, want 200", rr.Code)
	}
	var c struct {
		CaptchaID string `json:"captcha_id"`
		ImageSVG  string `json:"image_svg"`
		Format    string `json:"format"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &c); err != nil {
		t.Fatalf("parse captcha: %v", err)
	}
	if c.CaptchaID == "" || !strings.HasPrefix(c.ImageSVG, "<svg") || c.Format != "svg" {
		t.Fatalf("captcha shape: %+v", c)
	}
	id, answer, _ := generateCaptcha()
	return map[string]string{
		"captcha_id": id,
		"captcha":    answer,
	}
}

// TestCaptchaSVG: SVG 结构 + 大小写不敏感 + 一次性消费。
func TestCaptchaSVG(t *testing.T) {
	id, answer, svg := generateCaptcha()
	if len(answer) != 4 || !strings.HasPrefix(svg, "<svg") || !strings.Contains(svg, "</svg>") {
		t.Fatalf("bad captcha: answer=%q svg=%q", answer, svg)
	}
	if !verifyCaptcha(id, strings.ToLower(answer)) { // 小写提交也应通过
		t.Fatalf("verify lowercase failed")
	}
	if verifyCaptcha(id, answer) { // 一次性:已消费
		t.Fatalf("verify reused entry")
	}
}

// doReqRaw is doReq without captcha injection (used by fetchCaptcha itself
// to avoid recursion).
func doReqRaw(t *testing.T, ts *httptest.Server, method, path, body, token string) *httptest.ResponseRecorder {
	t.Helper()
	req, err := http.NewRequest(method, ts.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer resp.Body.Close()
	rr := httptest.NewRecorder()
	rr.Code = resp.StatusCode
	for k, vv := range resp.Header {
		for _, v := range vv {
			rr.Header().Add(k, v)
		}
	}
	rr.Body.ReadFrom(resp.Body)
	return rr
}

func TestAuthFlow(t *testing.T) {
	ts, db := newTestServer(t)

	// register
	mkw := base64.StdEncoding.EncodeToString([]byte("wrapped-key-bytes"))
	regBody := `{"username":"alice","email":"alice@example.com","password":"password123","master_key_wrapped":"` + mkw + `"}`
	reg := doReq(t, ts, http.MethodPost, "/api/v1/auth/register", regBody, "")
	if reg.Code != http.StatusCreated {
		t.Fatalf("register status = %d, want 201, body=%s", reg.Code, reg.Body.String())
	}
	var regResp struct {
		Token string `json:"token"`
		User  struct {
			ID       int64  `json:"id"`
			Username string `json:"username"`
			Email    string `json:"email"`
			Tier     string `json:"tier"`
		} `json:"user"`
	}
	if err := json.Unmarshal(reg.Body.Bytes(), &regResp); err != nil {
		t.Fatalf("parse register response: %v", err)
	}
	if regResp.Token == "" || regResp.User.Username != "alice" || regResp.User.Tier != "free" {
		t.Fatalf("unexpected register response: %+v", regResp)
	}

	// master_key_wrapped actually stored decoded in the BLOB column
	var stored []byte
	if err := db.QueryRow(`SELECT master_key_wrapped FROM users WHERE id = ?`, regResp.User.ID).Scan(&stored); err != nil {
		t.Fatalf("query stored key: %v", err)
	}
	if string(stored) != "wrapped-key-bytes" {
		t.Fatalf("stored master_key_wrapped = %q, want %q", stored, "wrapped-key-bytes")
	}

	// duplicate register -> 409
	dup := doReq(t, ts, http.MethodPost, "/api/v1/auth/register", regBody, "")
	if dup.Code != http.StatusConflict {
		t.Fatalf("duplicate register status = %d, want 409, body=%s", dup.Code, dup.Body.String())
	}

	// login
	login := doReq(t, ts, http.MethodPost, "/api/v1/auth/login",
		`{"username":"alice","password":"password123"}`, "")
	if login.Code != http.StatusOK {
		t.Fatalf("login status = %d, want 200, body=%s", login.Code, login.Body.String())
	}
	var loginResp struct {
		Token string `json:"token"`
		User  struct {
			ID int64 `json:"id"`
		} `json:"user"`
	}
	if err := json.Unmarshal(login.Body.Bytes(), &loginResp); err != nil {
		t.Fatalf("parse login response: %v", err)
	}
	if loginResp.Token == "" || loginResp.User.ID != regResp.User.ID {
		t.Fatalf("unexpected login response: %+v", loginResp)
	}

	// bad password -> 401
	bad := doReq(t, ts, http.MethodPost, "/api/v1/auth/login",
		`{"username":"alice","password":"wrongpass"}`, "")
	if bad.Code != http.StatusUnauthorized {
		t.Fatalf("bad login status = %d, want 401", bad.Code)
	}

	// me with token -> 200
	me := doReq(t, ts, http.MethodGet, "/api/v1/me", "", loginResp.Token)
	if me.Code != http.StatusOK {
		t.Fatalf("me status = %d, want 200, body=%s", me.Code, me.Body.String())
	}
	if !strings.Contains(me.Body.String(), `"username":"alice"`) {
		t.Fatalf("me response missing user: %s", me.Body.String())
	}

	// healthz still works
	hz := doReq(t, ts, http.MethodGet, "/healthz", "", "")
	if hz.Code != http.StatusOK || strings.TrimSpace(hz.Body.String()) != "ok" {
		t.Fatalf("healthz status = %d, body=%s", hz.Code, hz.Body.String())
	}
}

func TestMeUnauthorized(t *testing.T) {
	ts, _ := newTestServer(t)

	// no token -> 401
	me := doReq(t, ts, http.MethodGet, "/api/v1/me", "", "")
	if me.Code != http.StatusUnauthorized {
		t.Fatalf("me without token status = %d, want 401", me.Code)
	}

	// garbage token -> 401
	me2 := doReq(t, ts, http.MethodGet, "/api/v1/me", "", "not.a.jwt")
	if me2.Code != http.StatusUnauthorized {
		t.Fatalf("me with bad token status = %d, want 401", me2.Code)
	}
}

func TestLoginReturnsMasterSalt(t *testing.T) {
	ts, _ := newTestServer(t)

	// 注册时上传盐(跨设备恢复用),登录应原样返回。
	regBody := `{"username":"salty","email":"salty@example.com","password":"password123","master_salt":"abc123salt"}`
	if rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/register", regBody, ""); rr.Code != http.StatusCreated {
		t.Fatalf("register: status=%d body=%s", rr.Code, rr.Body.String())
	}
	rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/login", `{"username":"salty","password":"password123"}`, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("login: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		MasterSalt string `json:"master_salt"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse login: %v", err)
	}
	if resp.MasterSalt != "abc123salt" {
		t.Fatalf("login master_salt = %q, want abc123salt", resp.MasterSalt)
	}

	// 老用户(无盐):返回空串,不报错。
	regBody2 := `{"username":"nosalt","email":"nosalt@example.com","password":"password123"}`
	if rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/register", regBody2, ""); rr.Code != http.StatusCreated {
		t.Fatalf("register nosalt: status=%d", rr.Code)
	}
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/login", `{"username":"nosalt","password":"password123"}`, "")
	var resp2 struct {
		MasterSalt string `json:"master_salt"`
	}
	json.Unmarshal(rr.Body.Bytes(), &resp2)
	if resp2.MasterSalt != "" {
		t.Fatalf("nosalt user master_salt = %q, want empty", resp2.MasterSalt)
	}

	// 老账号回填:本机有盐 → PUT master-salt → 登录返回新盐。
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/login", `{"username":"nosalt","password":"password123"}`, "")
	var login2 struct {
		Token string `json:"token"`
	}
	json.Unmarshal(rr.Body.Bytes(), &login2)
	if login2.Token == "" {
		t.Fatalf("login nosalt: no token")
	}
	rr = doReq(t, ts, http.MethodPut, "/api/v1/settings/master-salt", `{"master_salt":"backfilled-salt"}`, login2.Token)
	if rr.Code != http.StatusOK {
		t.Fatalf("put master-salt: status=%d body=%s", rr.Code, rr.Body.String())
	}
	rr = doReq(t, ts, http.MethodPost, "/api/v1/auth/login", `{"username":"nosalt","password":"password123"}`, "")
	var resp3 struct {
		MasterSalt string `json:"master_salt"`
	}
	json.Unmarshal(rr.Body.Bytes(), &resp3)
	if resp3.MasterSalt != "backfilled-salt" {
		t.Fatalf("after backfill master_salt = %q, want backfilled-salt", resp3.MasterSalt)
	}
}

func TestRegisterValidation(t *testing.T) {
	ts, _ := newTestServer(t)
	cases := []string{
		`{"username":"","email":"a@b.c","password":"password123"}`,
		`{"username":"bob","email":"not-an-email","password":"password123"}`,
		`{"username":"bob","email":"b@b.c","password":"short"}`,
	}
	for _, body := range cases {
		rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/register", body, "")
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("validation case %s: status = %d, want 400", body, rr.Code)
		}
	}
}
