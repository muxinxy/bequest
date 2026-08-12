package main

import (
	"bytes"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net"
	"net/smtp"
	"strconv"
	"strings"
)

// sendMail is the SYSTEM sender (used by scheduler/notify), round-robining
// over the servers loaded at startup. Kept as the same signature/behavior as
// before: with no SMTP configured it logs and returns.
func sendMail(to, subject, body string) {
	sendMailSystem(to, subject, body)
}

// sendMailSystem tries each system SMTP server in turn, starting at the
// round-robin position, and logs which one succeeded.
func sendMailSystem(to, subject, body string) {
	if len(systemServers) == 0 {
		log.Printf("mail skipped (no SMTP config): to=%s subject=%s", to, subject)
		return
	}
	n := len(systemServers)
	start := rrIndex % n
	for i := 0; i < n; i++ {
		s := systemServers[(start+i)%n]
		if err := sendViaServer(s, to, subject, body); err != nil {
			log.Printf("send via %s: %v", s.Host, err)
			continue
		}
		rrIndex = (start + i + 1) % n
		log.Printf("mail sent via %s to=%s", s.Host, to)
		return
	}
	log.Printf("mail failed via all %d smtp servers: to=%s", n, to)
}

// sendMailCustom sends via one specific server (a user's own SMTP).
// Returns the send error so callers can fall back to the system sender.
func sendMailCustom(s smtpServer, to, subject, body string) error {
	return sendViaServer(s, to, subject, body)
}

// sendViaServer performs the actual net/smtp send through one server. Empty
// User -> no auth (plaintext relay); otherwise PLAIN auth. Port 465 is
// implicit TLS (QQ/163 授权码默认端口), port 587 uses STARTTLS — net/smtp's
// SendMail only does STARTTLS, so 465 needs a manual TLS dial.
func sendViaServer(s smtpServer, to, subject, body string) error {
	if s.Host == "" {
		return errors.New("empty smtp host")
	}
	port := s.Port
	if port == 0 {
		port = 587
	}
	from := s.FromAddr
	if from == "" {
		from = s.User
	}
	addr := net.JoinHostPort(s.Host, strconv.Itoa(port))
	// 信封 MAIL FROM 必须是无显示名的裸邮箱(带 "<名字>" 会被拒绝)。
	envFrom := extractMailbox(from)
	tlsCfg := &tls.Config{ServerName: s.Host, MinVersion: tls.VersionTLS12}
	var conn net.Conn
	var err error
	if port == 465 {
		conn, err = tls.Dial("tcp", addr, tlsCfg)
	} else {
		conn, err = net.Dial("tcp", addr)
	}
	if err != nil {
		return err
	}
	defer conn.Close()
	client, err := smtp.NewClient(conn, s.Host)
	if err != nil {
		return err
	}
	defer client.Close()
	// 非隐式 TLS 端口:优先 STARTTLS 升级,失败则回退明文(自托管中继常见)。
	if port != 465 && s.User != "" {
		if ok, _ := client.Extension("STARTTLS"); ok {
			if err := client.StartTLS(tlsCfg); err != nil {
				return err
			}
		}
	}
	if s.User != "" {
		if err := client.Auth(smtp.PlainAuth("", s.User, s.Password, s.Host)); err != nil {
			return err
		}
	}
	if err := client.Mail(envFrom); err != nil {
		return err
	}
	if err := client.Rcpt(to); err != nil {
		return err
	}
	w, err := client.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write([]byte(buildMessage(from, to, subject, body))); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return client.Quit()
}

// extractMailbox returns the bare email from "显示名 <a@b.c>" or a plain
// address unchanged — the envelope MAIL FROM must carry no display name.
func extractMailbox(s string) string {
	if i := strings.Index(s, "<"); i >= 0 && strings.HasSuffix(s, ">") {
		return s[i+1 : len(s)-1]
	}
	return s
}

// buildMessage renders a minimal MIME message: RFC 2047-encoded UTF-8
// subject and body. From/To keep a parseable RFC5322 mailbox — encoding the
// whole address breaks strict servers (QQ 550 "From header missing or
// invalid"); only a display-name prefix (if present) gets encoded.
func buildMessage(from, to, subject, body string) string {
	enc := func(s string) string {
		return "=?UTF-8?B?" + base64.StdEncoding.EncodeToString([]byte(s)) + "?="
	}
	// formatMailbox: "显示名 <a@b.c>" -> "=?UTF-8?B?显示名?= <a@b.c>",
	// plain "a@b.c" -> unchanged. RFC2047 encodes the name, never the address.
	formatMailbox := func(s string) string {
		if i := strings.Index(s, "<"); i >= 0 && strings.HasSuffix(s, ">") {
			name := strings.TrimSpace(s[:i])
			email := s[i:] // "<a@b.c>"
			if name == "" {
				return email
			}
			return enc(name) + " " + email
		}
		return s
	}
	var buf bytes.Buffer
	fmt.Fprintf(&buf, "From: %s\r\n", formatMailbox(from))
	fmt.Fprintf(&buf, "To: %s\r\n", formatMailbox(to))
	fmt.Fprintf(&buf, "Subject: %s\r\n", enc(subject))
	buf.WriteString("MIME-Version: 1.0\r\n")
	buf.WriteString("Content-Type: text/plain; charset=UTF-8\r\n")
	buf.WriteString("Content-Transfer-Encoding: base64\r\n\r\n")
	b64 := base64.StdEncoding.EncodeToString([]byte(body))
	for i := 0; i < len(b64); i += 76 {
		end := min(i+76, len(b64))
		buf.WriteString(b64[i:end])
		buf.WriteString("\r\n")
	}
	return buf.String()
}
