package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"strings"
	"time"
)

// ---------- TOTP (RFC 6238, 仅标准库) ----------
// 管理后台 2FA:HMAC-SHA1、30 秒步长、6 位数字、±1 步容差。
// 密钥为 20 字节随机 → base32(32 字符),兼容常见 TOTP App。

// generateTOTPSecret returns a base32-encoded 20-byte random secret.
func generateTOTPSecret() (string, error) {
	b := make([]byte, 20)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return strings.ToUpper(base32.StdEncoding.EncodeToString(b)), nil
}

// totpCode computes the 6-digit code for secret at time t.
func totpCode(secret string, t time.Time) (string, error) {
	key, err := base32.StdEncoding.DecodeString(strings.ToUpper(strings.TrimSpace(secret)))
	if err != nil {
		return "", err
	}
	msg := make([]byte, 8)
	binary.BigEndian.PutUint64(msg, uint64(t.Unix()/30))
	mac := hmac.New(sha1.New, key)
	mac.Write(msg)
	sum := mac.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	code := (uint32(sum[off])&0x7f)<<24 | uint32(sum[off+1])<<16 | uint32(sum[off+2])<<8 | uint32(sum[off+3])
	return fmt.Sprintf("%06d", code%1000000), nil
}

// verifyTOTP accepts the code within a ±1 step window (clock drift tolerance).
func verifyTOTP(secret, code string, now time.Time) bool {
	for i := -1; i <= 1; i++ {
		c, err := totpCode(secret, now.Add(time.Duration(i)*30*time.Second))
		if err == nil && c == code {
			return true
		}
	}
	return false
}
