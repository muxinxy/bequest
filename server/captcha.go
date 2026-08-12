package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math/big"
	"net/http"
	"sync"
	"time"
)

// ---------- 算术验证码(最简单有效,无外部依赖) ----------
// 服务端生成随机算式(如 "3 + 7 = ?"),答案 sha256 哈希存内存缓存
// (5 分钟过期),客户端提交 captcha_id + 答案,防机器人/防爆破。
// 单机内存缓存即可;多实例部署需换共享存储(本项目单二进制,足够)。

type captchaEntry struct {
	answerHash string
	expiresAt  time.Time
}

var (
	captchaMu    sync.Mutex
	captchaStore = map[string]captchaEntry{}
)

// captchaCleanup removes expired entries; called on each generation.
func captchaCleanup() {
	now := time.Now()
	for id, e := range captchaStore {
		if now.After(e.expiresAt) {
			delete(captchaStore, id)
		}
	}
}

// handleGetCaptcha: GET /api/v1/auth/captcha -> {"captcha_id","question"}
// question 形如 "3 + 7 = ?"(纯算术,无图像依赖)。
func handleGetCaptcha(w http.ResponseWriter, r *http.Request) {
	a, _ := rand.Int(rand.Reader, big.NewInt(10))
	b, _ := rand.Int(rand.Reader, big.NewInt(10))
	question := fmt.Sprintf("%d + %d = ?", a.Int64(), b.Int64())
	answer := a.Int64() + b.Int64()
	hash := sha256.Sum256([]byte(fmt.Sprintf("%d", answer)))
	idBytes := make([]byte, 8)
	rand.Read(idBytes)
	id := hex.EncodeToString(idBytes)

	captchaMu.Lock()
	captchaCleanup()
	captchaStore[id] = captchaEntry{
		answerHash: hex.EncodeToString(hash[:]),
		expiresAt:  time.Now().Add(5 * time.Minute),
	}
	captchaMu.Unlock()

	writeJSON(w, http.StatusOK, map[string]any{
		"captcha_id": id,
		"question":   question,
	})
}

// verifyCaptcha checks captcha_id + answer, consuming the entry.
// Returns true if valid; the entry is deleted on any attempt (one-time).
func verifyCaptcha(id, answer string) bool {
	if id == "" || answer == "" {
		return false
	}
	captchaMu.Lock()
	defer captchaMu.Unlock()
	e, ok := captchaStore[id]
	if !ok {
		return false
	}
	delete(captchaStore, id) // one-time use
	if time.Now().After(e.expiresAt) {
		return false
	}
	hash := sha256.Sum256([]byte(answer))
	return hex.EncodeToString(hash[:]) == e.answerHash
}
