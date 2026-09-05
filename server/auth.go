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
	UserID       int64 `json:"user_id"`
	TokenVersion int   `json:"token_version"`         // 改密后旧 token 失效
	Pending2FA   bool  `json:"pending_2fa,omitempty"` // 2FA 待验证短命令牌
	jwt.RegisteredClaims
}

// signToken issues a session token carrying the user's current token_version;
// requireAuth rejects tokens whose version differs from the DB (password change
// bumps the version, invalidating all previously issued tokens).
func signToken(userID int64, version int) (string, error) {
	now := time.Now()
	c := claims{
		UserID:       userID,
		TokenVersion: version,
		RegisteredClaims: jwt.RegisteredClaims{
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(tokenTTL)),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, c).SignedString(jwtSecret)
}

// sign2FAPendingToken issues a 5-minute token valid ONLY for the 2FA step;
// requireAuth rejects tokens carrying Pending2FA, so it can't be reused as a session.
func sign2FAPendingToken(userID int64) (string, error) {
	now := time.Now()
	c := claims{
		UserID:     userID,
		Pending2FA: true,
		RegisteredClaims: jwt.RegisteredClaims{
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(5 * time.Minute)),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, c).SignedString(jwtSecret)
}

// verifyToken returns the parsed claims of a valid HS256 token.
func verifyToken(tokenStr string) (*claims, error) {
	tok, err := jwt.ParseWithClaims(tokenStr, &claims{}, func(t *jwt.Token) (any, error) {
		if t.Method != jwt.SigningMethodHS256 {
			return nil, errors.New("unexpected signing method")
		}
		return jwtSecret, nil
	})
	if err != nil {
		return nil, err
	}
	c, ok := tok.Claims.(*claims)
	if !ok || !tok.Valid {
		return nil, errors.New("invalid token")
	}
	return c, nil
}

// ---------- handlers ----------

type userJSON struct {
	ID              int64  `json:"id"`
	Username        string `json:"username"`
	Email           string `json:"email"`
	Tier            string `json:"tier"`
	Role            string `json:"role"`
	Disabled        bool   `json:"disabled"`
	MemberExpiresAt string `json:"member_expires_at"` // 空串=非会员(或永久会员)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	// Localize Chinese error messages to the request language (resolved from
	// Accept-Language by the localize middleware). Untranslated strings pass
	// through unchanged.
	writeJSON(w, status, map[string]string{"error": translateErr(responseLang(w), msg)})
}

func validateCredentials(username, email, password string) string {
	if strings.TrimSpace(username) == "" || strings.TrimSpace(password) == "" {
		return "用户名和密码必填"
	}
	if len(password) < 8 {
		return "密码至少 8 个字符"
	}
	if !strings.Contains(email, "@") {
		return "邮箱必须包含 @"
	}
	return ""
}

type registerRequest struct {
	Username         string `json:"username"`
	Email            string `json:"email"`
	Password         string `json:"password"`
	MasterKeyWrapped string `json:"master_key_wrapped"`
	MasterSalt       string `json:"master_salt"` // 明文不敏感,跨设备登录恢复用
	CaptchaID        string `json:"captcha_id"`
	Captcha          string `json:"captcha"`
}

// handleRegister: POST /api/v1/auth/register -> 201 {token, user}; 409 dup; 400 validation
func handleRegister(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req registerRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if !verifyCaptcha(req.CaptchaID, req.Captcha) {
			writeError(w, http.StatusBadRequest, "验证码错误或已过期")
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
				writeError(w, http.StatusBadRequest, "master_key_wrapped 必须为 base64 编码")
				return
			}
			mkw = decoded
		}

		hash, err := hashPassword(req.Password)
		if err != nil {
			log.Printf("hash password: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}

		tx, err := db.Begin()
		if err != nil {
			log.Printf("begin register: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		id, err := execInsert(tx, `INSERT INTO users (username, email, password_hash, master_key_wrapped, master_salt) VALUES (?, ?, ?, ?, ?)`,
			req.Username, req.Email, hash, mkw, nullable(req.MasterSalt))
		if err != nil {
			tx.Rollback()
			if isUniqueViolation(err) {
				writeError(w, http.StatusConflict, "用户名或邮箱已被占用")
				return
			}
			log.Printf("insert user: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		// 每用户一条全局触发阶梯(免费档默认天数;会员开通后由 handleListTriggerLadders 补建)。
		if _, err := tx.Exec(`INSERT INTO trigger_ladders (user_id, name, is_global, days) VALUES (?, '全局', 1, ?)`,
			id, defaultLadderDays("free")); err != nil {
			tx.Rollback()
			log.Printf("seed global ladder: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		// Seed per-user preset categories (editable/deletable). Names are
		// distinct across types to satisfy UNIQUE(user_id, name).
		if _, err := tx.Exec(`INSERT INTO categories (user_id, name, asset_type, is_preset) VALUES
			(?, '房产','physical',1),(?, '车辆','physical',1),(?, '贵金属','physical',1),(?, '收藏品','physical',1),(?, '实体其他','physical',1),
			(?, '银行账户','virtual',1),(?, '证券投资','virtual',1),(?, '加密货币','virtual',1),(?, '数字账户','virtual',1),(?, '虚拟其他','virtual',1)`,
			id, id, id, id, id, id, id, id, id, id); err != nil {
			tx.Rollback()
			log.Printf("seed preset categories: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if err := tx.Commit(); err != nil {
			log.Printf("commit register: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusCreated, map[string]any{
			"token": mustSign(id, 0),
			"user":  userJSON{ID: id, Username: req.Username, Email: req.Email, Tier: "free", Role: "user"},
		})
	}
}

type loginRequest struct {
	Username  string `json:"username"`
	Password  string `json:"password"`
	CaptchaID string `json:"captcha_id"`
	Captcha   string `json:"captcha"`
}

// handleLogin: POST /api/v1/auth/login -> 200 {token, user}; 401 bad creds
// 用户名或邮箱均可登录(identifier 匹配 username 或 email);需通过算术验证码。
func handleLogin(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req loginRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if !verifyCaptcha(req.CaptchaID, req.Captcha) {
			writeError(w, http.StatusBadRequest, "验证码错误或已过期")
			return
		}
		var id int64
		var username, email, hash, tier, role string
		var disabled, tokenVersion int
		var salt sql.NullString
		identifier := strings.TrimSpace(req.Username)
		err := db.QueryRow(`SELECT id, username, email, password_hash, tier, role, disabled, master_salt, token_version FROM users
			WHERE username = ? OR email = ?`, identifier, identifier).
			Scan(&id, &username, &email, &hash, &tier, &role, &disabled, &salt, &tokenVersion)
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusUnauthorized, "用户名或密码错误")
			return
		}
		if err != nil {
			log.Printf("query user: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		// 管理员账号失败锁定:连续失败 5 次锁定 5 分钟(普通用户不启用)。
		if role == "admin" {
			var failCnt int
			var locked sql.NullString
			if err := db.QueryRow(`SELECT login_fail_count, locked_until FROM users WHERE id = ?`, id).
				Scan(&failCnt, &locked); err != nil {
				log.Printf("query admin lock: %v", err)
			}
			if locked.Valid && locked.String != "" && locked.String > time.Now().UTC().Format("2006-01-02 15:04:05") {
				writeError(w, http.StatusTooManyRequests, "尝试次数过多,账号已锁定,请 5 分钟后再试")
				return
			}
		}
		if disabled == 1 {
			writeError(w, http.StatusForbidden, "账号已被禁用")
			return
		}
		ok, err := verifyPassword(hash, req.Password)
		if err != nil || !ok {
			// 管理员登录失败计数:5 次锁定 5 分钟。
			if role == "admin" {
				if _, uerr := db.Exec(`UPDATE users SET login_fail_count = login_fail_count + 1 WHERE id = ?`, id); uerr != nil {
					log.Printf("admin login fail count: %v", uerr)
				}
				var failCnt int
				if err := db.QueryRow(`SELECT login_fail_count FROM users WHERE id = ?`, id).Scan(&failCnt); err == nil && failCnt >= 5 {
					if _, uerr := db.Exec(`UPDATE users SET locked_until = `+dbNowAdd("+5 minutes")+`, login_fail_count = 0 WHERE id = ?`, id); uerr != nil {
						log.Printf("admin lock: %v", uerr)
					}
				}
			}
			writeError(w, http.StatusUnauthorized, "用户名或密码错误")
			return
		}
		// 登录成功:清除锁定与失败计数。
		if role == "admin" {
			if _, uerr := db.Exec(`UPDATE users SET login_fail_count = 0, locked_until = NULL WHERE id = ?`, id); uerr != nil {
				log.Printf("admin unlock: %v", uerr)
			}
		}
		// 登录时会员过期自动降级,并取最新 tier/到期时间返回。
		syncMemberTier(db, id)
		var memberExpires string
		if err := db.QueryRow(`SELECT tier, COALESCE(member_expires_at, '') FROM users WHERE id = ?`, id).Scan(&tier, &memberExpires); err != nil {
			log.Printf("query tier after sync: %v", err)
		}
		// Login is the owner's "still alive" proof: reset the dead man's
		// switch — refresh last_login_at, drop any escalation/inheritance
		// state, and reverse outstanding inheritance events.
		var stage string
		if err := db.QueryRow(`SELECT inherit_stage FROM users WHERE id = ?`, id).Scan(&stage); err != nil {
			log.Printf("query inherit stage: %v", err)
			stage = "inactive"
		}
		if _, err := db.Exec(`UPDATE users SET last_login_at = `+dbNow()+`, inherit_stage = 'inactive', escalation_level = 0 WHERE id = ?`, id); err != nil {
			log.Printf("update login state: %v", err)
		}
		if stage != "" && stage != "inactive" {
			// 第三重窗口:登录即反转。pending 事件无条件反转;claimed 事件
			// 仅在 72h 反悔期内可反转(交接最终完成),无截止时间的历史事件可反转。
			if _, err := db.Exec(`UPDATE inheritance_events SET status = 'reversed', reversed_at = `+dbNow()+`
				WHERE user_id = ? AND (
					status = 'pending'
					OR (status = 'claimed' AND (reversable_until IS NULL OR reversable_until > `+dbNow()+`))
				)`, id); err != nil {
				log.Printf("reverse inheritance events: %v", err)
			}
			if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (?, 'owner', 'login_reset', ?)`,
				id, fmt.Sprintf("stage:%s→inactive", stage)); err != nil {
				log.Printf("audit login reset: %v", err)
			}
		}
		// 管理后台 2FA:管理员且已启用 TOTP → 先发 5 分钟待验证令牌,
		// 完成 2FA 后才签发正式会话令牌。
		var totpSecret sql.NullString
		if err := db.QueryRow(`SELECT totp_secret FROM users WHERE id = ?`, id).Scan(&totpSecret); err != nil {
			log.Printf("query totp: %v", err)
		}
		if role == "admin" && totpSecret.Valid && totpSecret.String != "" {
			pending, err := sign2FAPendingToken(id)
			if err != nil {
				log.Printf("sign pending token: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{
				"totp_required": true,
				"pending_token": pending,
			})
			return
		}
		// 管理后台安全:管理员完整登录(无 TOTP 或 2FA 通过)记审计。
		if role == "admin" {
			if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (?, 'owner', 'admin_login', ?)`,
				id, clientIP(r)); err != nil {
				log.Printf("audit admin login: %v", err)
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"token":       mustSign(id, tokenVersion),
			"user":        userJSON{ID: id, Username: username, Email: email, Tier: tier, Role: role, Disabled: disabled == 1, MemberExpiresAt: memberExpires},
			"master_salt": salt.String,
		})
	}
}

type verify2FARequest struct {
	PendingToken string `json:"pending_token"`
	Code         string `json:"code"`
}

// handleVerify2FA: POST /api/v1/auth/2fa/verify -> 200 {token, user}.
// 用待验证令牌 + TOTP 码完成 2FA,签发正式会话令牌。
func handleVerify2FA(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req verify2FARequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		c, err := verifyToken(req.PendingToken)
		if err != nil || !c.Pending2FA {
			writeError(w, http.StatusUnauthorized, "无效或已过期的令牌")
			return
		}
		var role, secret string
		var tokenVersion int
		if err := db.QueryRow(`SELECT role, totp_secret, token_version FROM users WHERE id = ?`, c.UserID).Scan(&role, &secret, &tokenVersion); err != nil {
			writeError(w, http.StatusUnauthorized, "用户已不存在")
			return
		}
		if role != "admin" || secret == "" {
			writeError(w, http.StatusForbidden, "2FA 未启用")
			return
		}
		if !verifyTOTP(secret, strings.TrimSpace(req.Code), time.Now()) {
			writeError(w, http.StatusUnauthorized, "无效的验证码")
			return
		}
		var username, email, tier, memberExpires string
		syncMemberTier(db, c.UserID)
		if err := db.QueryRow(`SELECT username, email, tier, COALESCE(member_expires_at, '') FROM users WHERE id = ?`, c.UserID).Scan(&username, &email, &tier, &memberExpires); err != nil {
			log.Printf("query 2fa user: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (?, 'owner', 'admin_login', ?)`,
			c.UserID, clientIP(r)); err != nil {
			log.Printf("audit admin login: %v", err)
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"token": mustSign(c.UserID, tokenVersion),
			"user":  userJSON{ID: c.UserID, Username: username, Email: email, Tier: tier, Role: role, MemberExpiresAt: memberExpires},
		})
	}
}

// handleMe: GET /api/v1/me (auth middleware runs first) -> 200 {user}
func handleMe(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := r.Context().Value(ctxUserIDKey).(int64)
		// 会员过期自动降级,再返回最新状态。
		syncMemberTier(db, uid)
		var username, email, tier, role, memberExpires string
		var disabled int
		err := db.QueryRow(`SELECT username, email, tier, role, disabled, COALESCE(member_expires_at, '') FROM users WHERE id = ?`, uid).
			Scan(&username, &email, &tier, &role, &disabled, &memberExpires)
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusUnauthorized, "用户已不存在")
			return
		}
		if err != nil {
			log.Printf("query me: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"user": userJSON{ID: uid, Username: username, Email: email, Tier: tier, Role: role, Disabled: disabled == 1, MemberExpiresAt: memberExpires},
		})
	}
}

// mustSign signs a token; panics on failure — token signing failing is a server misconfig.
func mustSign(id int64, version int) string {
	s, err := signToken(id, version)
	if err != nil {
		panic(fmt.Sprintf("sign token: %v", err))
	}
	return s
}

// isUniqueViolation detects unique-constraint violations across dialects
// (SQLite "UNIQUE constraint failed", MySQL duplicate entry, PG duplicate key).
func isUniqueViolation(err error) bool {
	return uniqueViolation(err)
}
