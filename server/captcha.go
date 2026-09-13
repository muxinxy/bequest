package main

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"math/big"
	"net/http"
	"strings"
)

// ---------- SVG 图形验证码(无外部依赖) ----------
// 4 位随机字符(去 0O1lI 易混淆)渲染成 SVG 图片,答案 sha256 哈希存 DB 表
// captchas(迁移 026,5 分钟过期):重启不失效,多实例部署共用一库即可。
// 客户端提交 captcha_id + 答案(比对前转大写),防机器人/防爆破。

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

// captchaPrune 清理过期条目;每次生成验证码时顺带执行(量小,无需调度器)。
func captchaPrune(db *sql.DB) {
	db.Exec("DELETE FROM captchas WHERE expires_at <= " + dbNow()) // 尽力而为
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

// generateCaptcha mints a fresh captcha(入库,5 分钟过期): returns its id,
// plaintext answer(内部用,供测试取答案;handler 不暴露)和 SVG 图片。
func generateCaptcha(db *sql.DB) (id, answer, svg string, err error) {
	var sb strings.Builder
	for i := 0; i < 4; i++ {
		sb.WriteByte(captchaChars[randInt(len(captchaChars))])
	}
	answer = sb.String() // 全大写
	hash := sha256.Sum256([]byte(answer))
	idBytes := make([]byte, 16)
	rand.Read(idBytes)
	id = hex.EncodeToString(idBytes)

	captchaPrune(db)
	if _, err = db.Exec(
		"INSERT INTO captchas (id, answer_hash, expires_at) VALUES (?, ?, "+dbNowAdd("5 minutes")+")",
		id, hex.EncodeToString(hash[:])); err != nil {
		return "", "", "", err
	}
	return id, answer, buildCaptchaSVG(answer), nil
}

// handleGetCaptcha: GET /api/v1/auth/captcha -> {"captcha_id","image_svg","format"}
func handleGetCaptcha(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, _, svg, err := generateCaptcha(db)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "验证码生成失败")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"captcha_id": id,
			"image_svg":  svg,
			"format":     "svg",
		})
	}
}

// verifyCaptcha checks captcha_id + answer(大小写不敏感),消费该条目。
// 任何尝试(无论对错)都删除该条目(one-time):先 SELECT 取哈希并校验未过期,
// 再无条件 DELETE 并以 RowsAffected 判定本次尝试是否为唯一消费者——并发重复
// 使用同一 id 时只有一方能通过。返回 true 表示有效。
func verifyCaptcha(db *sql.DB, id, answer string) bool {
	if id == "" || answer == "" {
		return false
	}
	var answerHash string
	err := db.QueryRow(
		"SELECT answer_hash FROM captchas WHERE id = ? AND expires_at > "+dbNow(), id,
	).Scan(&answerHash)
	if err != nil {
		return false // 不存在或已过期
	}
	res, err := db.Exec("DELETE FROM captchas WHERE id = ?", id)
	if err != nil {
		return false
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false // 已被并发请求消费
	}
	hash := sha256.Sum256([]byte(strings.ToUpper(answer)))
	return hex.EncodeToString(hash[:]) == answerHash
}
