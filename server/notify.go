package main

import (
	"database/sql"
	"log"
)

// notifyUser is the single dispatch point for user-facing reminders:
// in-app (reminders table, dedup key as today), email when SMTP is
// configured (sendMail self-skips otherwise), and — members only — the
// SMS/phone stubs below.
func notifyUser(db *sql.DB, uid int64, tier, typ, title, body, dedup string) {
	insertReminder(db, uid, typ, nil, title, body, dedup)
	var email string
	if err := db.QueryRow(`SELECT email FROM users WHERE id = ?`, uid).Scan(&email); err != nil {
		log.Printf("notifyUser: query email: %v", err)
	}
	sendMail(email, title, body)
	if tier == "member" {
		sendSMS("", body) // ponytail: users table has no phone column yet; phone capture is a future member field
		sendPhone("", body)
	}
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
