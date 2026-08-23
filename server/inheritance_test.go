package main

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// getUID looks up a user id by username.
func getUID(t *testing.T, db *sql.DB, username string) int64 {
	t.Helper()
	var id int64
	if err := db.QueryRow(`SELECT id FROM users WHERE username = ?`, username).Scan(&id); err != nil {
		t.Fatalf("get uid %s: %v", username, err)
	}
	return id
}

// setLastLogin rewinds last_login_at by a SQLite relative expression like "-40 days".
func setLastLogin(t *testing.T, db *sql.DB, uid int64, expr string) {
	t.Helper()
	if _, err := db.Exec(`UPDATE users SET last_login_at = datetime('now', ?) WHERE id = ?`, expr, uid); err != nil {
		t.Fatalf("set last_login_at %s: %v", expr, err)
	}
}

// createInheritor creates an inheritor via the API and returns its id.
func createInheritor(t *testing.T, ts *httptest.Server, token, name, email, code string) int64 {
	t.Helper()
	body := fmt.Sprintf(`{"name":%q,"email":%q,"access_code":%q}`, name, email, code)
	rr := doReq(t, ts, http.MethodPost, "/api/v1/inheritors", body, token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create inheritor: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var in inheritorJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &in); err != nil {
		t.Fatalf("parse inheritor: %v", err)
	}
	return in.ID
}

func countRows(t *testing.T, db *sql.DB, query string, args ...any) int {
	t.Helper()
	var n int
	if err := db.QueryRow(query, args...).Scan(&n); err != nil {
		t.Fatalf("count %s: %v", query, err)
	}
	return n
}

// ---------- 1. inheritors CRUD ----------

func TestInheritorsCRUD(t *testing.T) {
	ts, db := newTestServer(t)
	tokenA := registerUser(t, ts, "alice")

	// validation: empty name/email/access_code -> 400
	for _, body := range []string{
		`{"name":"","email":"b@x.com","access_code":"abc12345"}`,
		`{"name":"bob","email":"","access_code":"abc12345"}`,
		`{"name":"bob","email":"b@x.com","access_code":""}`,
	} {
		if rr := doReq(t, ts, http.MethodPost, "/api/v1/inheritors", body, tokenA); rr.Code != http.StatusBadRequest {
			t.Fatalf("validation %s: status=%d want 400", body, rr.Code)
		}
	}

	id := createInheritor(t, ts, tokenA, "bob", "bob@example.com", "abc12345")

	// sha256 hash stored, never plaintext
	var hash string
	if err := db.QueryRow(`SELECT access_code_hash FROM inheritors WHERE id = ?`, id).Scan(&hash); err != nil {
		t.Fatalf("query hash: %v", err)
	}
	if hash == "abc12345" {
		t.Fatal("access_code stored in plaintext")
	}
	if hash != hashAccessCode("abc12345") {
		t.Fatalf("stored hash %q != sha256(access_code)", hash)
	}

	// list: shape has no access_code_hash
	rr := doReq(t, ts, http.MethodGet, "/api/v1/inheritors", "", tokenA)
	if rr.Code != http.StatusOK {
		t.Fatalf("list inheritors: %d body=%s", rr.Code, rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), "access_code_hash") {
		t.Fatalf("list leaks access_code_hash: %s", rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), `"name":"bob"`) {
		t.Fatalf("list missing bob: %s", rr.Body.String())
	}

	// update with new code -> hash changes
	rr = doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/inheritors/%d", id),
		`{"name":"bobby","email":"bobby@example.com","access_code":"newcode99"}`, tokenA)
	if rr.Code != http.StatusOK {
		t.Fatalf("update inheritor: %d body=%s", rr.Code, rr.Body.String())
	}
	var newHash string
	if err := db.QueryRow(`SELECT access_code_hash FROM inheritors WHERE id = ?`, id).Scan(&newHash); err != nil {
		t.Fatalf("query new hash: %v", err)
	}
	if newHash == hash {
		t.Fatal("update did not re-hash access code")
	}

	// update without access_code -> hash unchanged
	rr = doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/inheritors/%d", id),
		`{"name":"bobby2","email":"bobby2@example.com"}`, tokenA)
	if rr.Code != http.StatusOK {
		t.Fatalf("update inheritor (no code): %d body=%s", rr.Code, rr.Body.String())
	}
	var kept string
	if err := db.QueryRow(`SELECT access_code_hash FROM inheritors WHERE id = ?`, id).Scan(&kept); err != nil {
		t.Fatalf("query kept hash: %v", err)
	}
	if kept != newHash {
		t.Fatal("update without access_code changed the hash")
	}

	// isolation: user B cannot touch A's inheritor
	tokenB := registerUser(t, ts, "bob")
	if rr := doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/inheritors/%d", id),
		`{"name":"x","email":"x@x.com"}`, tokenB); rr.Code != http.StatusNotFound {
		t.Fatalf("B update A's inheritor: %d want 404", rr.Code)
	}
	if rr := doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/inheritors/%d", id), "", tokenB); rr.Code != http.StatusNotFound {
		t.Fatalf("B delete A's inheritor: %d want 404", rr.Code)
	}

	// delete -> 204, then 404
	if rr := doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/inheritors/%d", id), "", tokenA); rr.Code != http.StatusNoContent {
		t.Fatalf("delete inheritor: %d want 204", rr.Code)
	}
	if rr := doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/inheritors/%d", id), "", tokenA); rr.Code != http.StatusNotFound {
		t.Fatalf("delete missing inheritor: %d want 404", rr.Code)
	}
}

// ---------- 2. reminder templates CRUD ----------

func TestTemplatesCRUD(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")

	// system defaults seeded by migration 002
	rr := doReq(t, ts, http.MethodGet, "/api/v1/reminder-templates", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("list templates: %d body=%s", rr.Code, rr.Body.String())
	}
	var list []templateJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
		t.Fatalf("parse templates: %v", err)
	}
	if len(list) < 3 {
		t.Fatalf("system presets not seeded: %s", rr.Body.String())
	}
	var sysID int64
	for _, tpl := range list {
		if tpl.IsPreset == 1 {
			sysID = tpl.ID
			break
		}
	}
	if sysID == 0 {
		t.Fatal("no system preset row")
	}

	// system row (user_id IS NULL) protected from PUT and DELETE
	if rr := doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/reminder-templates/%d", sysID),
		`{"name":"x","title_template":"t","body_template":"b"}`, token); rr.Code != http.StatusNotFound {
		t.Fatalf("PUT system template: %d want 404", rr.Code)
	}
	if rr := doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/reminder-templates/%d", sysID), "", token); rr.Code != http.StatusNotFound {
		t.Fatalf("DELETE system template: %d want 404", rr.Code)
	}

	// create own -> 201
	rr = doReq(t, ts, http.MethodPost, "/api/v1/reminder-templates",
		`{"name":"我的提醒","title_template":"提醒 {name}","body_template":"内容 {date}"}`, token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create template: %d body=%s", rr.Code, rr.Body.String())
	}
	var own templateJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &own); err != nil {
		t.Fatalf("parse created template: %v", err)
	}
	if own.IsPreset != 0 || own.Name != "我的提醒" {
		t.Fatalf("unexpected created template: %+v", own)
	}

	// empty fields -> 400
	for _, body := range []string{
		`{"name":"","title_template":"t","body_template":"b"}`,
		`{"name":"n","title_template":"","body_template":"b"}`,
		`{"name":"n","title_template":"t","body_template":""}`,
	} {
		if rr := doReq(t, ts, http.MethodPost, "/api/v1/reminder-templates", body, token); rr.Code != http.StatusBadRequest {
			t.Fatalf("create validation %s: %d want 400", body, rr.Code)
		}
	}

	// update own -> 200
	rr = doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/reminder-templates/%d", own.ID),
		`{"name":"改名","title_template":"t2","body_template":"b2"}`, token)
	if rr.Code != http.StatusOK {
		t.Fatalf("update own template: %d body=%s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), `"name":"改名"`) {
		t.Fatalf("update did not apply: %s", rr.Body.String())
	}

	// delete own -> 204
	if rr := doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/reminder-templates/%d", own.ID), "", token); rr.Code != http.StatusNoContent {
		t.Fatalf("delete own template: %d want 204", rr.Code)
	}
}

// ---------- 3. scheduler escalation + inheritance trigger ----------

func TestSchedulerEscalation(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")
	createInheritor(t, ts, token, "bob", "bob@example.com", "abc12345")

	// 40 days inactive (free tier) -> level 1, escalation reminder, no event
	setLastLogin(t, db, uid, "-40 days")
	scan(db, time.Now().UTC())

	var level int
	if err := db.QueryRow(`SELECT escalation_level FROM users WHERE id = ?`, uid).Scan(&level); err != nil {
		t.Fatalf("query level: %v", err)
	}
	if level != 1 {
		t.Fatalf("40 days: escalation_level=%d want 1", level)
	}
	if n := countRows(t, db, `SELECT COUNT(*) FROM reminders WHERE user_id=? AND type='escalation'`, uid); n != 1 {
		t.Fatalf("40 days: escalation reminders=%d want 1", n)
	}
	if n := countRows(t, db, `SELECT COUNT(*) FROM inheritance_events WHERE user_id=?`, uid); n != 0 {
		t.Fatalf("40 days: events=%d want 0", n)
	}
	var stage string
	if err := db.QueryRow(`SELECT inherit_stage FROM users WHERE id=?`, uid).Scan(&stage); err != nil {
		t.Fatalf("query stage: %v", err)
	}
	if stage != "inactive" {
		t.Fatalf("40 days: stage=%s want inactive", stage)
	}

	// 130 days -> top tier: level 3, event created, stage triggered, reminders + audit
	setLastLogin(t, db, uid, "-130 days")
	scan(db, time.Now().UTC())

	if err := db.QueryRow(`SELECT escalation_level FROM users WHERE id=?`, uid).Scan(&level); err != nil {
		t.Fatalf("query level 2: %v", err)
	}
	if level != 3 {
		t.Fatalf("130 days: escalation_level=%d want 3", level)
	}
	if n := countRows(t, db, `SELECT COUNT(*) FROM inheritance_events WHERE user_id=?`, uid); n != 1 {
		t.Fatalf("130 days: events=%d want 1", n)
	}
	if err := db.QueryRow(`SELECT inherit_stage FROM users WHERE id=?`, uid).Scan(&stage); err != nil {
		t.Fatalf("query stage 2: %v", err)
	}
	if stage != "triggered" {
		t.Fatalf("130 days: stage=%s want triggered", stage)
	}
	if n := countRows(t, db, `SELECT COUNT(*) FROM reminders WHERE user_id=? AND type='inheritance'`, uid); n != 1 {
		t.Fatalf("130 days: inheritance reminders=%d want 1", n)
	}
	if n := countRows(t, db, `SELECT COUNT(*) FROM audit_logs WHERE user_id=? AND action='inheritance_triggered'`, uid); n != 1 {
		t.Fatalf("130 days: trigger audits=%d want 1", n)
	}

	// event snapshots the inheritor's hash; event_key is 32 hex chars and in audit detail
	var eventKey, eventHash string
	if err := db.QueryRow(`SELECT event_key, access_code_hash FROM inheritance_events WHERE user_id=?`, uid).Scan(&eventKey, &eventHash); err != nil {
		t.Fatalf("query event: %v", err)
	}
	var inHash string
	if err := db.QueryRow(`SELECT access_code_hash FROM inheritors WHERE user_id=? ORDER BY id LIMIT 1`, uid).Scan(&inHash); err != nil {
		t.Fatalf("query inheritor hash: %v", err)
	}
	if eventHash != inHash {
		t.Fatalf("event hash %q != inheritor hash %q (not a snapshot)", eventHash, inHash)
	}
	if len(eventKey) != 32 {
		t.Fatalf("event_key len=%d want 32 hex chars", len(eventKey))
	}
	var detail sql.NullString
	if err := db.QueryRow(`SELECT detail FROM audit_logs WHERE user_id=? AND action='inheritance_triggered'`, uid).Scan(&detail); err != nil {
		t.Fatalf("query audit detail: %v", err)
	}
	if !detail.Valid || !strings.Contains(detail.String, eventKey) {
		t.Fatalf("audit detail missing event_key: %v", detail)
	}

	// re-scan -> still exactly one event (deduped)
	scan(db, time.Now().UTC())
	if n := countRows(t, db, `SELECT COUNT(*) FROM inheritance_events WHERE user_id=?`, uid); n != 1 {
		t.Fatalf("re-scan: events=%d want 1 (dedup)", n)
	}
}

// ---------- 3b. scheduler expiry reminders ----------

func TestSchedulerExpiry(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")

	now := time.Now().UTC()
	mkAsset := func(name, expiry string) {
		t.Helper()
		payload := base64.StdEncoding.EncodeToString([]byte("secret"))
		body := fmt.Sprintf(`{"name":%q,"asset_type":"virtual","encrypted_data":%q,"expiry_date":%q}`, name, payload, expiry)
		if rr := doReq(t, ts, http.MethodPost, "/api/v1/assets", body, token); rr.Code != http.StatusCreated {
			t.Fatalf("create asset %s: %d body=%s", name, rr.Code, rr.Body.String())
		}
	}
	mkAsset("银行卡", now.AddDate(0, 0, 25).Format("2006-01-02")) // -> advance 30 reminder
	mkAsset("电子邮箱", now.AddDate(0, 0, 5).Format("2006-01-02")) // -> advance 30 + 7 reminders
	mkAsset("旧卡", now.AddDate(0, 0, -2).Format("2006-01-02"))   // -> 已到期 reminder

	var id25, id5, idPast int64
	if err := db.QueryRow(`SELECT id FROM assets WHERE name='银行卡'`).Scan(&id25); err != nil {
		t.Fatalf("get asset 银行卡: %v", err)
	}
	if err := db.QueryRow(`SELECT id FROM assets WHERE name='电子邮箱'`).Scan(&id5); err != nil {
		t.Fatalf("get asset 电子邮箱: %v", err)
	}
	if err := db.QueryRow(`SELECT id FROM assets WHERE name='旧卡'`).Scan(&idPast); err != nil {
		t.Fatalf("get asset 旧卡: %v", err)
	}

	scan(db, now)

	// 25 days out: only the 30-day advance matches
	if n := countRows(t, db, `SELECT COUNT(*) FROM reminders WHERE user_id=? AND dedup_key=?`, uid, fmt.Sprintf("exp:%d:30", id25)); n != 1 {
		t.Fatalf("25d asset: exp:%d:30 missing", id25)
	}
	// 5 days out: 30 and 7 both match
	if n := countRows(t, db, `SELECT COUNT(*) FROM reminders WHERE user_id=? AND dedup_key=?`, uid, fmt.Sprintf("exp:%d:30", id5)); n != 1 {
		t.Fatalf("5d asset: exp:%d:30 missing", id5)
	}
	if n := countRows(t, db, `SELECT COUNT(*) FROM reminders WHERE user_id=? AND dedup_key=?`, uid, fmt.Sprintf("exp:%d:7", id5)); n != 1 {
		t.Fatalf("5d asset: exp:%d:7 missing", id5)
	}
	// expired asset: one 已到期 reminder
	if n := countRows(t, db, `SELECT COUNT(*) FROM reminders WHERE user_id=? AND dedup_key=?`, uid, fmt.Sprintf("exp:%d:past", idPast)); n != 1 {
		t.Fatalf("expired asset: exp:%d:past missing", idPast)
	}
	var pastBody string
	if err := db.QueryRow(`SELECT body FROM reminders WHERE user_id=? AND dedup_key=?`, uid, fmt.Sprintf("exp:%d:past", idPast)).Scan(&pastBody); err != nil {
		t.Fatalf("query past body: %v", err)
	}
	if !strings.Contains(pastBody, "旧卡") || !strings.Contains(pastBody, "已于") {
		t.Fatalf("unexpected expired body: %q", pastBody)
	}

	// re-scan -> no duplicates
	scan(db, now)
	if n := countRows(t, db, `SELECT COUNT(*) FROM reminders WHERE user_id=? AND type='expiry'`, uid); n != 4 {
		t.Fatalf("re-scan expiry reminders=%d want 4 (dedup)", n)
	}
}

// ---------- 4. claim ----------

func TestClaim(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")
	mkwB64 := base64.StdEncoding.EncodeToString([]byte("wrapped-key-bytes"))
	if _, err := db.Exec(`UPDATE users SET master_key_wrapped = ? WHERE id = ?`, []byte("wrapped-key-bytes"), uid); err != nil {
		t.Fatalf("set master key: %v", err)
	}
	createInheritor(t, ts, token, "bob", "bob@example.com", "abc12345")

	setLastLogin(t, db, uid, "-130 days")
	scan(db, time.Now().UTC())

	var eventKey string
	if err := db.QueryRow(`SELECT event_key FROM inheritance_events WHERE user_id = ?`, uid).Scan(&eventKey); err != nil {
		t.Fatalf("event not created: %v", err)
	}

	// unknown event_key -> 401
	if rr := doReq(t, ts, http.MethodPost, "/api/v1/inheritance/claim",
		`{"event_key":"nonexistent","access_code":"abc12345"}`, ""); rr.Code != http.StatusUnauthorized {
		t.Fatalf("unknown event: %d want 401", rr.Code)
	}
	// wrong access code -> 401
	body := fmt.Sprintf(`{"event_key":%q,"access_code":"wrongcode"}`, eventKey)
	if rr := doReq(t, ts, http.MethodPost, "/api/v1/inheritance/claim", body, ""); rr.Code != http.StatusUnauthorized {
		t.Fatalf("wrong code: %d want 401", rr.Code)
	}
	// correct code -> 200 with master_key_wrapped
	body = fmt.Sprintf(`{"event_key":%q,"access_code":"abc12345"}`, eventKey)
	rr := doReq(t, ts, http.MethodPost, "/api/v1/inheritance/claim", body, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("claim: %d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		MasterKeyWrapped string `json:"master_key_wrapped"`
		Status           string `json:"status"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse claim: %v", err)
	}
	if resp.MasterKeyWrapped != mkwB64 || resp.Status != "claimed" {
		t.Fatalf("unexpected claim response: %+v", resp)
	}
	// re-claim -> 409
	if rr := doReq(t, ts, http.MethodPost, "/api/v1/inheritance/claim", body, ""); rr.Code != http.StatusConflict {
		t.Fatalf("re-claim: %d want 409", rr.Code)
	}
	// stage claimed + audit actor inheritor:<event_id>
	var stage string
	if err := db.QueryRow(`SELECT inherit_stage FROM users WHERE id=?`, uid).Scan(&stage); err != nil {
		t.Fatalf("query stage: %v", err)
	}
	if stage != "claimed" {
		t.Fatalf("stage=%s want claimed", stage)
	}
	var actor string
	if err := db.QueryRow(`SELECT actor FROM audit_logs WHERE user_id=? AND action='inheritance_claimed'`, uid).Scan(&actor); err != nil {
		t.Fatalf("query claim audit: %v", err)
	}
	if !strings.HasPrefix(actor, "inheritor:") {
		t.Fatalf("claim actor=%q want inheritor:<id>", actor)
	}
}

// ---------- 5. login reset ----------

func TestLoginReset(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")
	if _, err := db.Exec(`UPDATE users SET master_key_wrapped = ? WHERE id = ?`, []byte("wrapped-key-bytes"), uid); err != nil {
		t.Fatalf("set master key: %v", err)
	}
	createInheritor(t, ts, token, "bob", "bob@example.com", "abc12345")

	setLastLogin(t, db, uid, "-130 days")
	scan(db, time.Now().UTC())
	var eventKey string
	if err := db.QueryRow(`SELECT event_key FROM inheritance_events WHERE user_id = ?`, uid).Scan(&eventKey); err != nil {
		t.Fatalf("event not created: %v", err)
	}

	// claim so the stage is 'claimed' with a claimed event
	body := fmt.Sprintf(`{"event_key":%q,"access_code":"abc12345"}`, eventKey)
	if rr := doReq(t, ts, http.MethodPost, "/api/v1/inheritance/claim", body, ""); rr.Code != http.StatusOK {
		t.Fatalf("claim for login reset: %d body=%s", rr.Code, rr.Body.String())
	}

	// owner logs in -> dead man's switch cancels
	rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/login", `{"username":"alice","password":"password123"}`, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("login: %d body=%s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), `"user"`) {
		t.Fatalf("login response shape changed: %s", rr.Body.String())
	}

	var stage string
	var level int
	if err := db.QueryRow(`SELECT inherit_stage, escalation_level FROM users WHERE id=?`, uid).Scan(&stage, &level); err != nil {
		t.Fatalf("query user after login: %v", err)
	}
	if stage != "inactive" {
		t.Fatalf("after login stage=%s want inactive", stage)
	}
	if level != 0 {
		t.Fatalf("after login escalation_level=%d want 0", level)
	}
	var evStatus string
	var reversed sql.NullString
	if err := db.QueryRow(`SELECT status, reversed_at FROM inheritance_events WHERE user_id=?`, uid).Scan(&evStatus, &reversed); err != nil {
		t.Fatalf("query event after login: %v", err)
	}
	if evStatus != "reversed" {
		t.Fatalf("event status=%s want reversed", evStatus)
	}
	if !reversed.Valid {
		t.Fatal("reversed_at not set")
	}
	var detail string
	if err := db.QueryRow(`SELECT detail FROM audit_logs WHERE user_id=? AND action='login_reset'`, uid).Scan(&detail); err != nil {
		t.Fatalf("query login_reset audit: %v", err)
	}
	if detail != "stage:claimed→inactive" {
		t.Fatalf("login_reset detail=%q want stage:claimed→inactive", detail)
	}
	// status endpoint reflects the reset
	rr = doReq(t, ts, http.MethodGet, "/api/v1/inheritance/status", "", token)
	if !strings.Contains(rr.Body.String(), `"stage":"inactive"`) {
		t.Fatalf("status after reset: %s", rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), `"status":"reversed"`) {
		t.Fatalf("status events not reversed: %s", rr.Body.String())
	}
}

// ---------- 6. reminders read ----------

func TestRemindersRead(t *testing.T) {
	ts, db := newTestServer(t)
	tokenA := registerUser(t, ts, "alice")
	uidA := getUID(t, db, "alice")

	if _, err := db.Exec(`INSERT INTO reminders (user_id, type, title, body, dedup_key) VALUES (?, 'expiry', 't1', 'b1', 'd1')`, uidA); err != nil {
		t.Fatalf("insert reminder 1: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO reminders (user_id, type, title, body, dedup_key) VALUES (?, 'escalation', 't2', 'b2', 'd2')`, uidA); err != nil {
		t.Fatalf("insert reminder 2: %v", err)
	}

	// list newest first
	rr := doReq(t, ts, http.MethodGet, "/api/v1/reminders", "", tokenA)
	if rr.Code != http.StatusOK {
		t.Fatalf("list reminders: %d body=%s", rr.Code, rr.Body.String())
	}
	var list []reminderJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
		t.Fatalf("parse reminders: %v", err)
	}
	if len(list) != 2 || list[0].Status != "pending" || list[0].Title != "t2" {
		t.Fatalf("unexpected reminder list: %+v", list)
	}

	// mark read -> 200, idempotent
	if rr := doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/reminders/%d/read", list[0].ID), "", tokenA); rr.Code != http.StatusOK {
		t.Fatalf("mark read: %d want 200", rr.Code)
	}
	if rr := doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/reminders/%d/read", list[0].ID), "", tokenA); rr.Code != http.StatusOK {
		t.Fatalf("mark read again (idempotent): %d want 200", rr.Code)
	}
	rr = doReq(t, ts, http.MethodGet, "/api/v1/reminders", "", tokenA)
	if !strings.Contains(rr.Body.String(), `"status":"read"`) {
		t.Fatalf("reminder not marked read: %s", rr.Body.String())
	}

	// cross-user read -> 404
	tokenB := registerUser(t, ts, "bob")
	if rr := doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/reminders/%d/read", list[0].ID), "", tokenB); rr.Code != http.StatusNotFound {
		t.Fatalf("B read A's reminder: %d want 404", rr.Code)
	}
}

// ---------- 7. audit log ----------

func TestAuditLog(t *testing.T) {
	ts, db := newTestServer(t)
	tokenA := registerUser(t, ts, "alice")
	uidA := getUID(t, db, "alice")
	tokenB := registerUser(t, ts, "bob")
	uidB := getUID(t, db, "bob")

	// generate real audit entries: inheritance trigger + login reset
	createInheritor(t, ts, tokenA, "bob", "bob@example.com", "abc12345")
	setLastLogin(t, db, uidA, "-130 days")
	scan(db, time.Now().UTC()) // -> inheritance_triggered audit

	rr := doReq(t, ts, http.MethodGet, "/api/v1/audit-log", "", tokenA)
	if rr.Code != http.StatusOK {
		t.Fatalf("audit log: %d body=%s", rr.Code, rr.Body.String())
	}
	var list []auditJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
		t.Fatalf("parse audit: %v", err)
	}
	if len(list) < 1 {
		t.Fatalf("audit log empty for A: %s", rr.Body.String())
	}
	if list[0].Action != "inheritance_triggered" || list[0].Actor != "system" {
		t.Fatalf("unexpected audit entry: %+v", list[0])
	}
	if list[0].Detail == nil || !strings.Contains(*list[0].Detail, "event_key=") {
		t.Fatalf("audit detail missing event_key: %+v", list[0])
	}

	// newest first: insert a second entry and re-check order
	if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (?, 'owner', 'login_reset', 'x')`, uidA); err != nil {
		t.Fatalf("insert audit: %v", err)
	}
	rr = doReq(t, ts, http.MethodGet, "/api/v1/audit-log", "", tokenA)
	if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
		t.Fatalf("parse audit 2: %v", err)
	}
	if list[0].Action != "login_reset" || list[1].Action != "inheritance_triggered" {
		t.Fatalf("audit not newest-first: %+v", list)
	}

	// isolation: B sees nothing
	if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, action) VALUES (?, 'owner', 'login_reset')`, uidB); err != nil {
		t.Fatalf("insert B audit: %v", err)
	}
	rr = doReq(t, ts, http.MethodGet, "/api/v1/audit-log", "", tokenB)
	if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
		t.Fatalf("parse B audit: %v", err)
	}
	if len(list) != 1 || list[0].Actor != "owner" {
		t.Fatalf("B audit not isolated: %+v", list)
	}
}

// ---------- 8. 资产级继承端到端 ----------

func TestAssetLevelInheritance(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")
	if _, err := db.Exec(`UPDATE users SET master_key_wrapped = ? WHERE id = ?`, []byte("wrapped-key-bytes"), uid); err != nil {
		t.Fatalf("set master key: %v", err)
	}

	// 创建资产并设置继承包装密钥 WK(claim 时发放给继承人)
	wkB64 := base64.StdEncoding.EncodeToString([]byte("asset-wk-bytes"))
	rr := doReq(t, ts, http.MethodPost, "/api/v1/assets",
		fmt.Sprintf(`{"name":"保险箱","asset_type":"virtual","encrypted_data":"QUJD","asset_key_wrapped_wk":%q}`, wkB64), token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create asset: %d body=%s", rr.Code, rr.Body.String())
	}
	var assetID int64
	if err := db.QueryRow(`SELECT id FROM assets WHERE user_id=?`, uid).Scan(&assetID); err != nil {
		t.Fatalf("get asset id: %v", err)
	}

	// 创建继承人 bob 并绑定到该资产(全局阶梯)
	bobID := createInheritor(t, ts, token, "bob", "bob@example.com", "abc12345")
	rr = doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/assets/%d/inheritors", assetID),
		fmt.Sprintf(`{"inheritor_id":%d,"ladder_id":null}`, bobID), token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("bind inheritor: %d body=%s", rr.Code, rr.Body.String())
	}

	// 130 天未登录 -> 触发资产级 pending 事件
	setLastLogin(t, db, uid, "-130 days")
	scan(db, time.Now().UTC())

	var eventKey, evStatus string
	if err := db.QueryRow(`SELECT event_key, status FROM inheritance_events WHERE user_id=? AND asset_id=?`, uid, assetID).
		Scan(&eventKey, &evStatus); err != nil {
		t.Fatalf("asset event not created: %v", err)
	}
	if evStatus != "pending" || eventKey == "" {
		t.Fatalf("event status=%q key=%q want pending+non-empty", evStatus, eventKey)
	}

	// 错误访问码 -> 401
	body := fmt.Sprintf(`{"event_key":%q,"access_code":"wrongcode"}`, eventKey)
	if rr := doReq(t, ts, http.MethodPost, "/api/v1/inheritance/claim", body, ""); rr.Code != http.StatusUnauthorized {
		t.Fatalf("wrong code: %d want 401", rr.Code)
	}
	// 正确访问码 -> 200 发放资产 WK
	body = fmt.Sprintf(`{"event_key":%q,"access_code":"abc12345"}`, eventKey)
	rr = doReq(t, ts, http.MethodPost, "/api/v1/inheritance/claim", body, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("claim: %d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		AssetKeyWrappedWk string `json:"asset_key_wrapped_wk"`
		AssetID           int64  `json:"asset_id"`
		Status            string `json:"status"`
		ReversableUntil   string `json:"reversable_until"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse claim: %v", err)
	}
	if resp.AssetKeyWrappedWk != wkB64 || resp.Status != "claimed" || resp.ReversableUntil == "" || resp.AssetID != assetID {
		t.Fatalf("unexpected claim response: %+v", resp)
	}

	// 事件状态已更新为 claimed
	if err := db.QueryRow(`SELECT status FROM inheritance_events WHERE user_id=? AND asset_id=?`, uid, assetID).
		Scan(&evStatus); err != nil {
		t.Fatalf("query event status: %v", err)
	}
	if evStatus != "claimed" {
		t.Fatalf("event status=%q want claimed", evStatus)
	}

	// 状态接口返回 claimed 事件与 reversable_until(72h 反悔窗口)
	rr = doReq(t, ts, http.MethodGet, "/api/v1/inheritance/status", "", token)
	if !strings.Contains(rr.Body.String(), `"status":"claimed"`) || !strings.Contains(rr.Body.String(), `"reversable_until"`) {
		t.Fatalf("status missing claimed/reversable_until: %s", rr.Body.String())
	}
}
