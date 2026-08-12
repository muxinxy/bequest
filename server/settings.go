package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
)

// dev-only fallback key; production MUST set ENCRYPTION_KEY (32 bytes).
const devEncryptionKey = "bequest-dev-key-change-me-0000"

var encKeyOnce sync.Once

// encryptionKey returns a 32-byte AES-256 key from ENCRYPTION_KEY (used
// as-is when 32 bytes, else SHA-256-derived) or the dev fallback.
func encryptionKey() []byte {
	k := os.Getenv("ENCRYPTION_KEY")
	if k == "" {
		encKeyOnce.Do(func() { log.Printf("ENCRYPTION_KEY not set, using dev key") })
		k = devEncryptionKey
	}
	if len(k) == 32 {
		return []byte(k)
	}
	sum := sha256.Sum256([]byte(k))
	return sum[:]
}

// encryptSecret returns AES-256-GCM ciphertext: nonce||ciphertext||tag.
func encryptSecret(plaintext string) ([]byte, error) {
	block, err := aes.NewCipher(encryptionKey())
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return gcm.Seal(nonce, nonce, []byte(plaintext), nil), nil
}

// decryptSecret reverses encryptSecret; blobs encrypted under an older key
// fail here and the caller falls back to the system sender.
func decryptSecret(blob []byte) (string, error) {
	block, err := aes.NewCipher(encryptionKey())
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	if len(blob) < gcm.NonceSize() {
		return "", errors.New("ciphertext too short")
	}
	nonce, ct := blob[:gcm.NonceSize()], blob[gcm.NonceSize():]
	pt, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		return "", err
	}
	return string(pt), nil
}

// ---------- /api/v1/settings/smtp ----------

// smtpSettingsJSON is the shared GET/PUT response shape; the password is
// never returned.
type smtpSettingsJSON struct {
	Configured bool   `json:"configured"`
	Host       string `json:"host"`
	Port       int    `json:"port"`
	User       string `json:"user"`
	FromAddr   string `json:"from_addr"`
	Enabled    bool   `json:"enabled"`
}

func scanSMTPSettings(w http.ResponseWriter, uid int64, db *sql.DB) (smtpSettingsJSON, bool) {
	var s smtpSettingsJSON
	var enabled int
	err := db.QueryRow(`SELECT host, port, user, from_addr, enabled FROM user_smtp WHERE user_id = ?`, uid).
		Scan(&s.Host, &s.Port, &s.User, &s.FromAddr, &enabled)
	if errors.Is(err, sql.ErrNoRows) {
		return smtpSettingsJSON{Configured: false}, true
	}
	if err != nil {
		log.Printf("get smtp settings: %v", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return smtpSettingsJSON{}, false
	}
	s.Configured = true
	s.Enabled = enabled != 0
	return s, true
}

// handleGetSMTP: GET /api/v1/settings/smtp -> 200 settings or configured:false
func handleGetSMTP(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s, ok := scanSMTPSettings(w, userID(r), db)
		if !ok {
			return
		}
		writeJSON(w, http.StatusOK, s)
	}
}

// handleGetInheritanceToggle: GET /api/v1/settings/inheritance -> 200 {"enabled":bool}
func handleGetInheritanceToggle(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var enabled int
		if err := db.QueryRow(`SELECT inheritance_enabled FROM users WHERE id = ?`, userID(r)).Scan(&enabled); err != nil {
			log.Printf("query inheritance toggle: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"enabled": enabled != 0})
	}
}

// handlePutInheritanceToggle: PUT /api/v1/settings/inheritance {"enabled":bool}
func handlePutInheritanceToggle(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Enabled bool `json:"enabled"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		v := 0
		if req.Enabled {
			v = 1
		}
		if _, err := db.Exec(`UPDATE users SET inheritance_enabled = ? WHERE id = ?`, v, userID(r)); err != nil {
			log.Printf("update inheritance toggle: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"enabled": req.Enabled})
	}
}

type smtpPutRequest struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	User     string `json:"user"`
	Password string `json:"password"`
	FromAddr string `json:"from_addr"`
	Enabled  *bool  `json:"enabled"`
}

// handlePutSMTP: PUT /api/v1/settings/smtp -> 200 same shape as GET.
// Empty password keeps the stored encrypted one; a first-time setup requires one.
func handlePutSMTP(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req smtpPutRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		req.Host = strings.TrimSpace(req.Host)
		if req.Host == "" {
			writeError(w, http.StatusBadRequest, "host is required")
			return
		}
		if req.Port < 1 || req.Port > 65535 {
			writeError(w, http.StatusBadRequest, "port must be 1-65535")
			return
		}
		var enc []byte
		if req.Password != "" {
			e, err := encryptSecret(req.Password)
			if err != nil {
				log.Printf("encrypt smtp password: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			enc = e
		} else {
			err := db.QueryRow(`SELECT password_enc FROM user_smtp WHERE user_id = ?`, uid).Scan(&enc)
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusBadRequest, "password is required for first-time setup")
				return
			}
			if err != nil {
				log.Printf("query smtp password: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
		}
		enabled := 1
		if req.Enabled != nil && !*req.Enabled {
			enabled = 0
		}
		if _, err := db.Exec(`INSERT INTO user_smtp (user_id, host, port, user, password_enc, from_addr, enabled, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
			ON CONFLICT(user_id) DO UPDATE SET
				host = excluded.host, port = excluded.port, user = excluded.user,
				password_enc = excluded.password_enc, from_addr = excluded.from_addr,
				enabled = excluded.enabled, updated_at = datetime('now')`,
			uid, req.Host, req.Port, req.User, enc, req.FromAddr, enabled); err != nil {
			log.Printf("upsert smtp settings: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, smtpSettingsJSON{
			Configured: true,
			Host:       req.Host,
			Port:       req.Port,
			User:       req.User,
			FromAddr:   req.FromAddr,
			Enabled:    req.Enabled == nil || *req.Enabled,
		})
	}
}

// handleDeleteSMTP: DELETE /api/v1/settings/smtp -> 200 configured:false (idempotent)
func handleDeleteSMTP(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, err := db.Exec(`DELETE FROM user_smtp WHERE user_id = ?`, userID(r)); err != nil {
			log.Printf("delete smtp settings: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, smtpSettingsJSON{Configured: false})
	}
}

// handleVersion: GET /api/v1/version -> 200 {"version": version} (no auth)
func handleVersion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"version": version})
}

// ---------- /api/v1/settings/master-salt ----------

// handlePutMasterSalt: PUT /api/v1/settings/master-salt -> 200 {"ok":true}.
// 老账号回填:注册时未上传盐,客户端在登录时检测服务端缺盐而本机有 → 回填,
// 之后新设备即可凭「主密码 + 盐」跨设备恢复密钥。
func handlePutMasterSalt(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req struct {
			MasterSalt string `json:"master_salt"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		if strings.TrimSpace(req.MasterSalt) == "" {
			writeError(w, http.StatusBadRequest, "master_salt required")
			return
		}
		if _, err := db.Exec(`UPDATE users SET master_salt = ?, updated_at = datetime('now') WHERE id = ?`,
			req.MasterSalt, uid); err != nil {
			log.Printf("update master salt: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	}
}

// ---------- /api/v1/settings/master-key ----------

type masterKeyPutRequest struct {
	Password         string `json:"password"`
	MasterKeyWrapped string `json:"master_key_wrapped"`
}

// handlePutMasterKey: PUT /api/v1/settings/master-key -> 200 {"ok":true}.
// Client re-wraps the master key after a password change; we require proof of
// the account password so a stolen JWT alone cannot break the handover.
func handlePutMasterKey(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req masterKeyPutRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		var hash string
		if err := db.QueryRow(`SELECT password_hash FROM users WHERE id = ?`, uid).Scan(&hash); err != nil {
			log.Printf("query user password hash: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		ok, err := verifyPassword(hash, req.Password)
		if err != nil || !ok {
			writeError(w, http.StatusUnauthorized, "invalid password")
			return
		}
		decoded, err := base64.StdEncoding.DecodeString(req.MasterKeyWrapped)
		if err != nil || len(decoded) == 0 {
			writeError(w, http.StatusBadRequest, "master_key_wrapped must be base64")
			return
		}
		if _, err := db.Exec(`UPDATE users SET master_key_wrapped = ?, updated_at = datetime('now') WHERE id = ?`, decoded, uid); err != nil {
			log.Printf("update master key: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (?, 'owner', 'master_key_updated', ?)`,
			uid, fmt.Sprintf("bytes:%d", len(decoded))); err != nil {
			log.Printf("audit master key update: %v", err)
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	}
}
