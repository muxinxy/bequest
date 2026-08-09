package main

import (
	"database/sql"
	"errors"
	"log"
)

// notifyUser is the single dispatch point for user-facing reminders:
// in-app (reminders table, dedup key as today), email via the user's own
// SMTP when configured (falling back to system SMTP), and — members only —
// the SMS/phone stubs below.
func notifyUser(db *sql.DB, uid int64, tier, typ, title, body, dedup string) {
	insertReminder(db, uid, typ, nil, title, body, dedup)
	var email string
	if err := db.QueryRow(`SELECT email FROM users WHERE id = ?`, uid).Scan(&email); err != nil {
		log.Printf("notifyUser: query email: %v", err)
	}
	if !sendCustomForUser(db, uid, email, title, body) {
		sendMail(email, title, body)
	}
	if tier == "member" {
		sendSMS("", body) // ponytail: users table has no phone column yet; phone capture is a future member field
		sendPhone("", body)
	}
}

// sendCustomForUser sends via the recipient user's own SMTP server when a row
// exists, is enabled and has a host; returns true when it sent (so the caller
// skips the system sender). Decryption failure falls back to system.
func sendCustomForUser(db *sql.DB, uid int64, to, subject, body string) bool {
	var host, user, from string
	var port, enabled int
	var enc []byte
	err := db.QueryRow(`SELECT host, port, user, password_enc, from_addr, enabled FROM user_smtp WHERE user_id = ?`, uid).
		Scan(&host, &port, &user, &enc, &from, &enabled)
	if errors.Is(err, sql.ErrNoRows) || host == "" || enabled == 0 {
		return false
	}
	if err != nil {
		log.Printf("notifyUser: query user smtp: %v", err)
		return false
	}
	pass, err := decryptSecret(enc)
	if err != nil {
		log.Printf("notifyUser: decrypt smtp password: %v", err)
		return false
	}
	sendMailCustom(smtpServer{Host: host, Port: port, User: user, Password: pass, FromAddr: from}, to, subject, body)
	return true
}

// sendSMS and sendPhone are the reserved member-only channel endpoints.
// Stubs until a real SMS/phone provider is wired up — they only log, but the
// dispatch point and its tier gating already exist here.
func sendSMS(phone, body string) {
	log.Printf("sms not configured, skipping: %s", body)
}

func sendPhone(phone, body string) {
	log.Printf("phone not configured, skipping: %s", body)
}
