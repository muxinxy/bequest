package main

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net"
	"net/smtp"
	"strconv"
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
func sendMailCustom(s smtpServer, to, subject, body string) {
	if err := sendViaServer(s, to, subject, body); err != nil {
		log.Printf("send custom mail via %s: %v", s.Host, err)
	}
}

// sendViaServer performs the actual net/smtp send through one server. Empty
// User -> no auth (plaintext relay); otherwise PLAIN auth over STARTTLS.
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
	var auth smtp.Auth
	if s.User != "" {
		auth = smtp.PlainAuth("", s.User, s.Password, s.Host)
	}
	return smtp.SendMail(net.JoinHostPort(s.Host, strconv.Itoa(port)), auth, from, []string{to}, []byte(buildMessage(from, to, subject, body)))
}

// buildMessage renders a minimal MIME message: RFC 2047-encoded UTF-8
// headers and a base64 body.
func buildMessage(from, to, subject, body string) string {
	enc := func(s string) string {
		return "=?UTF-8?B?" + base64.StdEncoding.EncodeToString([]byte(s)) + "?="
	}
	var buf bytes.Buffer
	fmt.Fprintf(&buf, "From: %s\r\n", enc(from))
	fmt.Fprintf(&buf, "To: %s\r\n", enc(to))
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
