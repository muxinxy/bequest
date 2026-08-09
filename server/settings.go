package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
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
