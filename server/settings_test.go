package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// TestSMTPCRUD exercises the /api/v1/settings/smtp lifecycle: PUT stores an
// encrypted password (never returned), empty-password PUT keeps the old one,
// DELETE clears the row.
func TestSMTPCRUD(t *testing.T) {
	t.Setenv("ENCRYPTION_KEY", "") // force the dev fallback key so decrypt assertions are deterministic
	ts, db := newTestServer(t)

	reg := doReq(t, ts, http.MethodPost, "/api/v1/auth/register",
		`{"username":"privacy","email":"p@x.com","password":"password123"}`, "")
	if reg.Code != http.StatusCreated {
		t.Fatalf("register status = %d, want 201", reg.Code)
	}
	var regResp struct {
		Token string `json:"token"`
		User  struct {
			ID int64 `json:"id"`
		} `json:"user"`
	}
	if err := json.Unmarshal(reg.Body.Bytes(), &regResp); err != nil {
		t.Fatalf("parse register response: %v", err)
	}
	token, uid := regResp.Token, regResp.User.ID

	const pw = "smtp-secret-123"
	// first-time PUT requires a non-empty password
	first := doReq(t, ts, http.MethodPut, "/api/v1/settings/smtp",
		`{"host":"smtp.example.com","port":587,"password":""}`, token)
	if first.Code != http.StatusBadRequest {
		t.Fatalf("empty password first setup status = %d, want 400, body=%s", first.Code, first.Body.String())
	}

	put := doReq(t, ts, http.MethodPut, "/api/v1/settings/smtp",
		`{"host":"smtp.example.com","port":587,"user":"p@x.com","password":"`+pw+`","from_addr":"p@x.com","enabled":true}`, token)
	if put.Code != http.StatusOK {
		t.Fatalf("PUT status = %d, want 200, body=%s", put.Code, put.Body.String())
	}
	if !strings.Contains(put.Body.String(), `"configured":true`) || !strings.Contains(put.Body.String(), `"host":"smtp.example.com"`) {
		t.Fatalf("PUT response missing fields: %s", put.Body.String())
	}
	if strings.Contains(put.Body.String(), "password") {
		t.Fatalf("PUT response leaked password field: %s", put.Body.String())
	}

	// stored password is encrypted, and round-trips with the (dev) key
	var enc []byte
	var host string
	if err := db.QueryRow(`SELECT password_enc, host FROM user_smtp WHERE user_id = ?`, uid).Scan(&enc, &host); err != nil {
		t.Fatalf("query stored row: %v", err)
	}
	if host != "smtp.example.com" {
		t.Fatalf("stored host = %q, want smtp.example.com", host)
	}
	if bytes.Equal(enc, []byte(pw)) {
		t.Fatalf("password stored in plaintext")
	}
	if got, err := decryptSecret(enc); err != nil || got != pw {
		t.Fatalf("decrypt round-trip = %q, err=%v, want %q", got, err, pw)
	}

	// empty password on update keeps the old encrypted password
	put2 := doReq(t, ts, http.MethodPut, "/api/v1/settings/smtp",
		`{"host":"smtp.other.com","port":465,"password":"","from_addr":"other@x.com"}`, token)
	if put2.Code != http.StatusOK {
		t.Fatalf("PUT(keep pw) status = %d, want 200, body=%s", put2.Code, put2.Body.String())
	}
	var enc2 []byte
	if err := db.QueryRow(`SELECT password_enc FROM user_smtp WHERE user_id = ?`, uid).Scan(&enc2); err != nil {
		t.Fatalf("query updated row: %v", err)
	}
	if got, err := decryptSecret(enc2); err != nil || got != pw {
		t.Fatalf("kept password decrypt = %q, err=%v, want %q", got, err, pw)
	}

	// GET never returns a password field
	get := doReq(t, ts, http.MethodGet, "/api/v1/settings/smtp", "", token)
	if get.Code != http.StatusOK || !strings.Contains(get.Body.String(), `"configured":true`) {
		t.Fatalf("GET status = %d, body=%s", get.Code, get.Body.String())
	}
	if strings.Contains(get.Body.String(), "password") {
		t.Fatalf("GET leaked password field: %s", get.Body.String())
	}

	// DELETE is idempotent and resets to configured:false
	del := doReq(t, ts, http.MethodDelete, "/api/v1/settings/smtp", "", token)
	if del.Code != http.StatusOK || !strings.Contains(del.Body.String(), `"configured":false`) {
		t.Fatalf("DELETE status = %d, body=%s", del.Code, del.Body.String())
	}
	del2 := doReq(t, ts, http.MethodDelete, "/api/v1/settings/smtp", "", token)
	if del2.Code != http.StatusOK {
		t.Fatalf("second DELETE status = %d, want 200", del2.Code)
	}
	get2 := doReq(t, ts, http.MethodGet, "/api/v1/settings/smtp", "", token)
	if get2.Code != http.StatusOK || !strings.Contains(get2.Body.String(), `"configured":false`) {
		t.Fatalf("GET after DELETE status = %d, body=%s", get2.Code, get2.Body.String())
	}

	// port validation
	bad := doReq(t, ts, http.MethodPut, "/api/v1/settings/smtp",
		`{"host":"smtp.example.com","port":0,"password":"x"}`, token)
	if bad.Code != http.StatusBadRequest {
		t.Fatalf("bad port status = %d, want 400", bad.Code)
	}
	bad2 := doReq(t, ts, http.MethodPut, "/api/v1/settings/smtp",
		`{"host":"","port":587,"password":"x"}`, token)
	if bad2.Code != http.StatusBadRequest {
		t.Fatalf("empty host status = %d, want 400", bad2.Code)
	}
}

// TestVersionEndpoint checks /api/v1/version (no auth) returns the package var.
func TestVersionEndpoint(t *testing.T) {
	ts, _ := newTestServer(t)
	version = "9.9.9-test"
	defer func() { version = "dev" }()

	rr := doReq(t, ts, http.MethodGet, "/api/v1/version", "", "")
	if rr.Code != http.StatusOK {
		t.Fatalf("version status = %d, want 200", rr.Code)
	}
	if !strings.Contains(rr.Body.String(), `"version":"9.9.9-test"`) {
		t.Fatalf("version body = %s, want the version var", rr.Body.String())
	}
}

// TestSendMailSystemNoConfig: with no config.json/env SMTP the system sender
// must skip (log) without panicking.
func TestSendMailSystemNoConfig(t *testing.T) {
	sendMailSystem("a@b.c", "subject", "body") // must not panic
}

// TestNotifyUserPrefersUserSMTP: a user_smtp row points at an unreachable
// host; notifyUser must attempt the send, fail, and not panic.
func TestNotifyUserPrefersUserSMTP(t *testing.T) {
	t.Setenv("ENCRYPTION_KEY", "")
	ts, db := newTestServer(t)

	reg := doReq(t, ts, http.MethodPost, "/api/v1/auth/register",
		`{"username":"ownmail","email":"own@x.com","password":"password123"}`, "")
	if reg.Code != http.StatusCreated {
		t.Fatalf("register status = %d, want 201", reg.Code)
	}
	var regResp struct {
		User struct {
			ID int64 `json:"id"`
		} `json:"user"`
	}
	if err := json.Unmarshal(reg.Body.Bytes(), &regResp); err != nil {
		t.Fatalf("parse register response: %v", err)
	}
	uid := regResp.User.ID

	enc, err := encryptSecret("own-smtp-pass")
	if err != nil {
		t.Fatalf("encrypt test password: %v", err)
	}
	// 127.0.0.1:1 -> connection refused instantly; send fails, notifyUser must survive
	if _, err := db.Exec(`INSERT INTO user_smtp (user_id, host, port, user, password_enc, from_addr, enabled)
		VALUES (?, '127.0.0.1', 1, 'own@x.com', ?, 'own@x.com', 1)`, uid, enc); err != nil {
		t.Fatalf("insert user smtp row: %v", err)
	}

	notifyUser(db, uid, "free", "expiry", "到期提醒", "正文", "dedup:user-smtp") // must not panic

	// second user without a row still gets processed (system fallback path)
	reg2 := doReq(t, ts, http.MethodPost, "/api/v1/auth/register",
		`{"username":"plain","email":"plain@x.com","password":"password123"}`, "")
	if reg2.Code != http.StatusCreated {
		t.Fatalf("register2 status = %d, want 201", reg2.Code)
	}
	var reg2Resp struct {
		User struct {
			ID int64 `json:"id"`
		} `json:"user"`
	}
	if err := json.Unmarshal(reg2.Body.Bytes(), &reg2Resp); err != nil {
		t.Fatalf("parse register2 response: %v", err)
	}
	notifyUser(db, reg2Resp.User.ID, "free", "expiry", "到期提醒", "正文", "dedup:system-fallback")
}
