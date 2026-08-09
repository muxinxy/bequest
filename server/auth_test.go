package main

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

// newTestServer builds the full app wiring against a throwaway temp DB file
// (never touches data/bequest.db).
func newTestServer(t *testing.T) (*httptest.Server, *sql.DB) {
	t.Helper()
	dir := t.TempDir()
	db, err := sql.Open("sqlite", "file:"+filepath.Join(dir, "test.db")+
		"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
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
}

// doReq performs a request against the test server through the real HTTP stack.
func doReq(t *testing.T, ts *httptest.Server, method, path, body, token string) *httptest.ResponseRecorder {
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
