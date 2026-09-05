package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"
)

// ---------- SVG 图形验证码(无外部依赖) ----------
// 4 位随机字符(去 0O1lI 易混淆)渲染成 SVG 图片,答案 sha256 哈希存内存缓存
// (5 分钟过期),客户端提交 captcha_id + 答案(比对前转大写),防机器人/防爆破。
// 单机内存缓存即可;多实例部署需换共享存储(本项目单二进制,足够)。

type captchaEntry struct {
	answerHash string
	expiresAt  time.Time
}

var (
	captchaMu    sync.Mutex
	captchaStore = map[string]captchaEntry{}
)

// captchaChars: 去易混淆字符 0/O/1/I(小写 l 不会出现)。
const captchaChars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

// 深色系文字颜色 + 浅色干扰线/噪点颜色。
var (
	captchaTextColors = []string{"#2d2d2d", "#404040", "#1f1f1f", "#4a2f2f", "#2f3d4a"}
	captchaLineColors = []string{"#bdbdbd", "#cfcfcf", "#a8a8a8"}
)

func randInt(n int) int {
	v, _ := rand.Int(rand.Reader, big.NewInt(int64(n)))
	return int(v.Int64())
}

// captchaCleanup removes expired entries; called on each generation.
func captchaCleanup() {
	now := time.Now()
	for id, e := range captchaStore {
		if now.After(e.expiresAt) {
			delete(captchaStore, id)
		}
	}
}

// buildCaptchaSVG renders code as a 120x40 SVG: 每字符随机旋转 ±20°、深色、
// 位置轻微偏移;2-3 条浅色干扰线;20-30 个噪点;浅灰背景。
func buildCaptchaSVG(code string) string {
	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40" viewBox="0 0 120 40">`)
	b.WriteString(`<rect width="120" height="40" fill="#f0f0f0"/>`)
	// 干扰线:2-3 条浅色直线或二次贝塞尔曲线。
	for i := 0; i < 2+randInt(2); i++ {
		x1, y1 := randInt(110), randInt(35)
		x2, y2 := x1+5+randInt(40), randInt(35)
		color := captchaLineColors[randInt(len(captchaLineColors))]
		if randInt(2) == 0 {
			fmt.Fprintf(&b, `<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="1"/>`, x1, y1, x2, y2, color)
		} else {
			fmt.Fprintf(&b, `<path d="M%d %d Q%d %d %d %d" stroke="%s" stroke-width="1" fill="none"/>`,
				x1, y1, (x1+x2)/2+randInt(20), randInt(35), x2, y2, color)
		}
	}
	// 噪点:20-30 个。
	for i := 0; i < 20+randInt(11); i++ {
		fmt.Fprintf(&b, `<circle cx="%d" cy="%d" r="1" fill="%s"/>`,
			randInt(120), randInt(40), captchaLineColors[randInt(len(captchaLineColors))])
	}
	// 字符:随机旋转 ±20°、深色、位置轻微偏移。
	for i, ch := range code {
		x := 12 + i*26 + randInt(11) - 5 // -5 ~ +5
		y := 26 + randInt(9) - 4         // -4 ~ +4
		angle := randInt(41) - 20        // -20 ~ +20
		color := captchaTextColors[randInt(len(captchaTextColors))]
		fmt.Fprintf(&b, `<text x="%d" y="%d" font-size="22" font-family="sans-serif" font-weight="bold" fill="%s" transform="rotate(%d %d %d)">%c</text>`,
			x, y, color, angle, x, y, ch)
	}
	b.WriteString(`</svg>`)
	return b.String()
}

// generateCaptcha mints a fresh captcha: returns its id, plaintext answer
// (内部用,供测试取答案;handler 不暴露)和 SVG 图片。
func generateCaptcha() (id, answer, svg string) {
	var sb strings.Builder
	for i := 0; i < 4; i++ {
		sb.WriteByte(captchaChars[randInt(len(captchaChars))])
	}
	answer = sb.String() // 全大写
	hash := sha256.Sum256([]byte(answer))
	idBytes := make([]byte, 8)
	rand.Read(idBytes)
	id = hex.EncodeToString(idBytes)

	captchaMu.Lock()
	captchaCleanup()
	captchaStore[id] = captchaEntry{
		answerHash: hex.EncodeToString(hash[:]),
		expiresAt:  time.Now().Add(5 * time.Minute),
	}
	captchaMu.Unlock()
	return id, answer, buildCaptchaSVG(answer)
}

// handleGetCaptcha: GET /api/v1/auth/captcha -> {"captcha_id","image_svg","format"}
func handleGetCaptcha(w http.ResponseWriter, r *http.Request) {
	id, _, svg := generateCaptcha()
	writeJSON(w, http.StatusOK, map[string]any{
		"captcha_id": id,
		"image_svg":  svg,
		"format":     "svg",
	})
}

// verifyCaptcha checks captcha_id + answer(大小写不敏感),消费该条目。
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
	hash := sha256.Sum256([]byte(strings.ToUpper(answer)))
	return hex.EncodeToString(hash[:]) == e.answerHash
}
