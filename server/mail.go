package main

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"log"
	"net"
	"net/smtp"
	"os"
)

// sendMail sends a UTF-8 text email via the SMTP server configured in env
// (SMTP_HOST/SMTP_PORT/SMTP_USER/SMTP_PASS/SMTP_FROM). With no SMTP_HOST it
// logs and returns — mail is optional.
func sendMail(to, subject, body string) {
	host := os.Getenv("SMTP_HOST")
	if host == "" {
		log.Printf("mail skipped (no SMTP config): to=%s subject=%s", to, subject)
		return
	}
	port := os.Getenv("SMTP_PORT")
	if port == "" {
		port = "587"
	}
	user := os.Getenv("SMTP_USER")
	pass := os.Getenv("SMTP_PASS")
	from := os.Getenv("SMTP_FROM")
	if from == "" {
		from = user
	}
	var auth smtp.Auth
	if user != "" {
		auth = smtp.PlainAuth("", user, pass, host)
	}
	if err := smtp.SendMail(net.JoinHostPort(host, port), auth, from, []string{to}, []byte(buildMessage(from, to, subject, body))); err != nil {
		log.Printf("send mail: %v", err)
	}
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
