package main

import (
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/argon2"
)

// dev-only fallback secret; set JWT_SECRET in production.
const devJWTSecret = "bequest-dev-secret-change-me"

var jwtSecret = func() []byte {
	if s := os.Getenv("JWT_SECRET"); s != "" {
		return []byte(s)
	}
	return []byte(devJWTSecret)
}()

const tokenTTL = 24 * time.Hour

// ---------- argon2id ----------

type argonParams struct {
	time    uint32
	memory  uint32
	threads uint8
	keyLen  uint32
	saltLen int
}

// ponytail: one fixed OWASP-recommended params set; no per-user tuning needed.
var argon = argonParams{time: 3, memory: 64 * 1024, threads: 4, keyLen: 32, saltLen: 16}

// hashPassword returns a PHC-encoded argon2id string: $argon2id$v=19$m=...,t=...,p=...$salt$hash
func hashPassword(password string) (string, error) {
	salt := make([]byte, argon.saltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(password), salt, argon.time, argon.memory, argon.threads, argon.keyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argon.memory, argon.time, argon.threads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key)), nil
}

func verifyPassword(encoded, password string) (bool, error) {
	parts := strings.Split(encoded, "$")
	// $argon2id$v=19$m=...,t=...,p=...$salt$hash -> 6 parts
	if len(parts) != 6 || parts[1] != "argon2id" {
		return false, errors.New("malformed PHC string")
	}
	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil || version != argon2.Version {
		return false, errors.New("unsupported argon2 version")
	}
	var m, t uint32
	var p uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &m, &t, &p); err != nil {
		return false, errors.New("malformed argon2 params")
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return false, err
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return false, err
	}
	got := argon2.IDKey([]byte(password), salt, t, m, p, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1, nil
}

// ---------- JWT ----------

type claims struct {
	UserID int64 `json:"user_id"`
	jwt.RegisteredClaims
}

func signToken(userID int64) (string, error) {
	now := time.Now()
	c := claims{
		UserID: userID,
		RegisteredClaims: jwt.RegisteredClaims{
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(tokenTTL)),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, c).SignedString(jwtSecret)
}

// verifyToken returns the user_id from a valid HS256 token.
func verifyToken(tokenStr string) (int64, error) {
	tok, err := jwt.ParseWithClaims(tokenStr, &claims{}, func(t *jwt.Token) (any, error) {
		if t.Method != jwt.SigningMethodHS256 {
			return nil, errors.New("unexpected signing method")
		}
		return jwtSecret, nil
	})
	if err != nil {
		return 0, err
	}
	c, ok := tok.Claims.(*claims)
	if !ok || !tok.Valid {
		return 0, errors.New("invalid token")
	}
	return c.UserID, nil
}

// ---------- handlers ----------

type userJSON struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
	Email    string `json:"email"`
	Tier     string `json:"tier"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func validateCredentials(username, email, password string) string {
	if strings.TrimSpace(username) == "" || strings.TrimSpace(password) == "" {
		return "username and password are required"
	}
	if len(password) < 8 {
		return "password must be at least 8 characters"
	}
	if !strings.Contains(email, "@") {
		return "email must contain @"
	}
	return ""
}

type registerRequest struct {
	Username         string `json:"username"`
	Email            string `json:"email"`
	Password         string `json:"password"`
	MasterKeyWrapped string `json:"master_key_wrapped"`
}

// handleRegister: POST /api/v1/auth/register -> 201 {token, user}; 409 dup; 400 validation
func handleRegister(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req registerRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		if msg := validateCredentials(req.Username, req.Email, req.Password); msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		// master_key_wrapped is a base64 string; store decoded bytes in the BLOB column.
		var mkw []byte
		if req.MasterKeyWrapped != "" {
			decoded, err := base64.StdEncoding.DecodeString(req.MasterKeyWrapped)
			if err != nil {
				writeError(w, http.StatusBadRequest, "master_key_wrapped must be base64")
				return
			}
			mkw = decoded
		}

		hash, err := hashPassword(req.Password)
		if err != nil {
			log.Printf("hash password: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}

		res, err := db.Exec(`INSERT INTO users (username, email, password_hash, master_key_wrapped) VALUES (?, ?, ?, ?)`,
			req.Username, req.Email, hash, mkw)
		if err != nil {
			if isUniqueViolation(err) {
				writeError(w, http.StatusConflict, "username or email already taken")
				return
			}
			log.Printf("insert user: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		id, _ := res.LastInsertId()
		writeJSON(w, http.StatusCreated, map[string]any{
			"token": mustSign(id),
			"user":  userJSON{ID: id, Username: req.Username, Email: req.Email, Tier: "free"},
		})
	}
}

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// handleLogin: POST /api/v1/auth/login -> 200 {token, user}; 401 bad creds
func handleLogin(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req loginRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		var id int64
		var username, email, hash, tier string
		err := db.QueryRow(`SELECT id, username, email, password_hash, tier FROM users WHERE username = ?`, req.Username).
			Scan(&id, &username, &email, &hash, &tier)
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusUnauthorized, "invalid username or password")
			return
		}
		if err != nil {
			log.Printf("query user: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		ok, err := verifyPassword(hash, req.Password)
		if err != nil || !ok {
			writeError(w, http.StatusUnauthorized, "invalid username or password")
			return
		}
		// ponytail: last_login_at best-effort; not required by the contract
		db.Exec(`UPDATE users SET last_login_at = datetime('now') WHERE id = ?`, id)
		writeJSON(w, http.StatusOK, map[string]any{
			"token": mustSign(id),
			"user":  userJSON{ID: id, Username: username, Email: email, Tier: tier},
		})
	}
}

// handleMe: GET /api/v1/me (auth middleware runs first) -> 200 {user}
func handleMe(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := r.Context().Value(ctxUserIDKey).(int64)
		var username, email, tier string
		err := db.QueryRow(`SELECT username, email, tier FROM users WHERE id = ?`, uid).
			Scan(&username, &email, &tier)
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusUnauthorized, "user no longer exists")
			return
		}
		if err != nil {
			log.Printf("query me: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"user": userJSON{ID: uid, Username: username, Email: email, Tier: tier},
		})
	}
}

// mustSign signs a token; panics on failure — token signing failing is a server misconfig.
func mustSign(id int64) string {
	s, err := signToken(id)
	if err != nil {
		panic(fmt.Sprintf("sign token: %v", err))
	}
	return s
}

// isUniqueViolation detects SQLite UNIQUE constraint errors.
func isUniqueViolation(err error) bool {
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}
