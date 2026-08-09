package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// TestMasterKeyUpdate covers PUT /api/v1/settings/master-key: password proof,
// base64 validation, DB row update, audit log, and /me non-exposure.
func TestMasterKeyUpdate(t *testing.T) {
	ts, db := newTestServer(t)

	reg := doReq(t, ts, http.MethodPost, "/api/v1/auth/register",
		`{"username":"mkuser","email":"mk@x.com","password":"password123","master_key_wrapped":"`+
			base64.StdEncoding.EncodeToString([]byte("old-wrapped-key"))+`"}`, "")
	if reg.Code != http.StatusCreated {
		t.Fatalf("register status = %d, want 201, body=%s", reg.Code, reg.Body.String())
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

	// no token -> 401
	if rr := doReq(t, ts, http.MethodPut, "/api/v1/settings/master-key",
		`{"password":"password123","master_key_wrapped":"bmV3LWtleQ=="}`, ""); rr.Code != http.StatusUnauthorized {
		t.Fatalf("no token status = %d, want 401", rr.Code)
	}

	// wrong password -> 401
	if rr := doReq(t, ts, http.MethodPut, "/api/v1/settings/master-key",
		`{"password":"wrongpass","master_key_wrapped":"bmV3LWtleQ=="}`, token); rr.Code != http.StatusUnauthorized {
		t.Fatalf("wrong password status = %d, want 401, body=%s", rr.Code, rr.Body.String())
	}

	// empty master_key_wrapped -> 400
	if rr := doReq(t, ts, http.MethodPut, "/api/v1/settings/master-key",
		`{"password":"password123","master_key_wrapped":""}`, token); rr.Code != http.StatusBadRequest {
		t.Fatalf("empty mkw status = %d, want 400", rr.Code)
	}

	// invalid base64 -> 400
	if rr := doReq(t, ts, http.MethodPut, "/api/v1/settings/master-key",
		`{"password":"password123","master_key_wrapped":"!!!not-base64!!!"}`, token); rr.Code != http.StatusBadRequest {
		t.Fatalf("invalid base64 status = %d, want 400", rr.Code)
	}

	// correct password + valid base64 -> 200 {"ok":true}
	newKey := base64.StdEncoding.EncodeToString([]byte("new-wrapped-key"))
	put := doReq(t, ts, http.MethodPut, "/api/v1/settings/master-key",
		`{"password":"password123","master_key_wrapped":"`+newKey+`"}`, token)
	if put.Code != http.StatusOK || !strings.Contains(put.Body.String(), `"ok":true`) {
		t.Fatalf("PUT status = %d, body=%s, want 200 ok:true", put.Code, put.Body.String())
	}

	// DB row updated to the decoded bytes
	var stored []byte
	if err := db.QueryRow(`SELECT master_key_wrapped FROM users WHERE id = ?`, uid).Scan(&stored); err != nil {
		t.Fatalf("query stored key: %v", err)
	}
	if string(stored) != "new-wrapped-key" {
		t.Fatalf("stored master_key_wrapped = %q, want %q", stored, "new-wrapped-key")
	}

	// audit row written
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM audit_logs WHERE user_id = ? AND actor = 'owner' AND action = 'master_key_updated'`, uid).Scan(&n); err != nil {
		t.Fatalf("count audit rows: %v", err)
	}
	if n != 1 {
		t.Fatalf("audit rows = %d, want 1", n)
	}

	// /me unaffected and never exposes the wrapped key
	me := doReq(t, ts, http.MethodGet, "/api/v1/me", "", token)
	if me.Code != http.StatusOK {
		t.Fatalf("me status = %d, want 200", me.Code)
	}
	if strings.Contains(me.Body.String(), "master_key") || strings.Contains(me.Body.String(), "wrapped") {
		t.Fatalf("me leaked master key material: %s", me.Body.String())
	}
}
