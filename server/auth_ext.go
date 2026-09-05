package main

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

// ---------- 用户名/邮箱查重(注册实时校验) ----------

// handleCheckUsername: GET /api/v1/auth/check?username=xxx -> {"available":bool}
func handleCheckUsername(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimSpace(r.URL.Query().Get("username"))
		if name == "" {
			writeError(w, http.StatusBadRequest, "用户名必填")
			return
		}
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM users WHERE username = ?`, name).Scan(&n); err != nil {
			log.Printf("check username: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"available": n == 0})
	}
}

// handleCheckEmail: GET /api/v1/auth/check-email?email=xxx -> {"available":bool}
func handleCheckEmail(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		email := strings.TrimSpace(r.URL.Query().Get("email"))
		if email == "" {
			writeError(w, http.StatusBadRequest, "邮箱必填")
			return
		}
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM users WHERE email = ?`, email).Scan(&n); err != nil {
			log.Printf("check email: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"available": n == 0})
	}
}

// ---------- 修改用户名/邮箱 ----------

type updateProfileRequest struct {
	Username *string `json:"username"`
	Email    *string `json:"email"`
}

// handleUpdateProfile: PUT /api/v1/me -> 200 {user}
// 用户名/邮箱二选一更新;与已有用户冲突返回 409。
func handleUpdateProfile(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req updateProfileRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		updates := []string{}
		args := []any{}
		if req.Username != nil {
			name := strings.TrimSpace(*req.Username)
			if name == "" {
				writeError(w, http.StatusBadRequest, "用户名必填")
				return
			}
			updates = append(updates, "username = ?")
			args = append(args, name)
		}
		if req.Email != nil {
			email := strings.TrimSpace(*req.Email)
			if email == "" || !strings.Contains(email, "@") {
				writeError(w, http.StatusBadRequest, "无效的邮箱")
				return
			}
			updates = append(updates, "email = ?")
			args = append(args, email)
		}
		if len(updates) == 0 {
			writeError(w, http.StatusBadRequest, "没有需要更新的内容")
			return
		}
		args = append(args, uid)
		res, err := db.Exec(fmt.Sprintf(`UPDATE users SET %s, updated_at = `+dbNow()+` WHERE id = ?`,
			strings.Join(updates, ", ")), args...)
		if err != nil {
			if isUniqueViolation(err) {
				writeError(w, http.StatusConflict, "用户名或邮箱已被占用")
				return
			}
			log.Printf("update profile: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "用户不存在")
			return
		}
		var username, email, tier string
		if err := db.QueryRow(`SELECT username, email, tier FROM users WHERE id = ?`, uid).
			Scan(&username, &email, &tier); err != nil {
			log.Printf("query updated user: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"user": userJSON{ID: uid, Username: username, Email: email, Tier: tier},
		})
	}
}

// ---------- 登录后修改账户密码 ----------

// handleChangePassword: PUT /api/v1/me/password {"password","new_password"}
// 校验当前密码 → 更新哈希 → 递增 token_version(旧 token 全部失效)→ 审计。
func handleChangePassword(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req struct {
			Password    string `json:"password"`
			NewPassword string `json:"new_password"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if msg := validateCredentials("change-password", "pw@"+req.Password, req.NewPassword); msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		var hash string
		if err := db.QueryRow(`SELECT password_hash FROM users WHERE id = ?`, uid).Scan(&hash); err != nil {
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		ok, err := verifyPassword(hash, req.Password)
		if err != nil || !ok {
			writeError(w, http.StatusUnauthorized, "当前密码错误")
			return
		}
		newHash, err := hashPassword(req.NewPassword)
		if err != nil {
			log.Printf("hash new password: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if _, err := db.Exec(`UPDATE users SET password_hash = ?, token_version = token_version + 1, updated_at = `+dbNow()+` WHERE id = ?`,
			newHash, uid); err != nil {
			log.Printf("change password: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (?, 'owner', 'password_changed', ?)`,
			uid, clientIP(r)); err != nil {
			log.Printf("audit password change: %v", err)
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	}
}

// ---------- 忘记密码:邮箱验证码 ----------

// handleRequestPasswordReset: POST /api/v1/auth/reset-request {"email":...}
// 存在该邮箱则生成 6 位验证码邮件发送;不存在也返回 200(防枚举)。
func handleRequestPasswordReset(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Email string `json:"email"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		email := strings.TrimSpace(req.Email)
		var uid int64
		err := db.QueryRow(`SELECT id FROM users WHERE email = ?`, email).Scan(&uid)
		if errors.Is(err, sql.ErrNoRows) {
			// 邮箱不存在:返回成功但不发码,防账号枚举。
			writeJSON(w, http.StatusOK, map[string]any{"ok": true})
			return
		}
		if err != nil {
			log.Printf("query reset user: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		// 6 位数字验证码。
		code := fmt.Sprintf("%06d", mustRandomInt(1000000))
		hash := sha256.Sum256([]byte(code))
		expires := time.Now().UTC().Add(10 * time.Minute).Format("2006-01-02 15:04:05")
		if _, err := db.Exec(`INSERT INTO password_resets (user_id, code_hash, expires_at) VALUES (?, ?, ?)`,
			uid, hex.EncodeToString(hash[:]), expires); err != nil {
			log.Printf("insert reset code: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		// 邮件发送:优先用户自配 SMTP,失败回退系统 SMTP(与提醒邮件同策略)。
		// 全部失败仍返回成功(自托管 SMTP 可能未配,码存审计便于调试)。
		// 主题/正文按目标账号的语言偏好("托孤: " 品牌前缀保留)。
		lang := userLang(db, uid)
		subject := "托孤: " + userMsg(lang, "重置密码验证码")
		body := fmt.Sprintf(userMsg(lang, "您的验证码是: %s\n10 分钟内有效。若非本人操作请忽略。"), code)
		if !sendCustomForUser(db, uid, email, subject, body) {
			sendMail(email, subject, body)
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	}
}

// handleResetPassword: POST /api/v1/auth/reset {"email","code","new_password"}
// 验证码校验(10 分钟内、未使用)后重置账户密码;验证码标记已用。
func handleResetPassword(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Email       string `json:"email"`
			Code        string `json:"code"`
			NewPassword string `json:"new_password"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		email := strings.TrimSpace(req.Email)
		if msg := validateCredentials("reset-user", email, req.NewPassword); msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		// 定位该用户最新一条未使用且未过期的验证码:先做尝试次数检查,
		// 再比对验证码(5 次失败作废,防穷举)。
		var uid int64
		var resetID int64
		var attempts int
		var storedHash string
		err := db.QueryRow(`SELECT pr.user_id, pr.id, pr.attempts, pr.code_hash FROM password_resets pr
			JOIN users u ON u.id = pr.user_id
			WHERE u.email = ? AND pr.used = 0 AND pr.expires_at > `+dbNow()+`
			ORDER BY pr.id DESC LIMIT 1`, email).Scan(&uid, &resetID, &attempts, &storedHash)
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusUnauthorized, "无效或已过期的验证码")
			return
		}
		if err != nil {
			log.Printf("query reset code: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if attempts >= 5 {
			// 已超过尝试上限:作废该码。
			db.Exec(`UPDATE password_resets SET used = 1 WHERE id = ?`, resetID)
			writeError(w, http.StatusTooManyRequests, "尝试次数过多,请重新获取验证码")
			return
		}
		codeHash := sha256.Sum256([]byte(strings.TrimSpace(req.Code)))
		if hex.EncodeToString(codeHash[:]) != storedHash {
			attempts++
			used := 0
			if attempts >= 5 {
				used = 1
			}
			if _, err := db.Exec(`UPDATE password_resets SET attempts = ?, used = ? WHERE id = ?`, attempts, used, resetID); err != nil {
				log.Printf("count reset attempt: %v", err)
			}
			writeError(w, http.StatusUnauthorized, "无效或已过期的验证码")
			return
		}
		hash, err := hashPassword(req.NewPassword)
		if err != nil {
			log.Printf("hash new password: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		tx, err := db.Begin()
		if err != nil {
			log.Printf("begin reset: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if _, err := tx.Exec(`UPDATE users SET password_hash = ?, updated_at = `+dbNow()+` WHERE id = ?`,
			hash, uid); err != nil {
			tx.Rollback()
			log.Printf("update password: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if _, err := tx.Exec(`UPDATE password_resets SET used = 1 WHERE id = ?`, resetID); err != nil {
			tx.Rollback()
			log.Printf("mark reset used: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if err := tx.Commit(); err != nil {
			log.Printf("commit reset: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, action, detail) VALUES (?, 'owner', 'password_reset', 'via email code')`,
			uid); err != nil {
			log.Printf("audit reset: %v", err)
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	}
}

// mustRandomInt returns a cryptographically random int in [0, n).
func mustRandomInt(n int) int {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return 0
	}
	v := int64(0)
	for _, x := range b {
		v = v<<8 | int64(x)
	}
	if v < 0 {
		v = -v
	}
	return int(v % int64(n))
}
