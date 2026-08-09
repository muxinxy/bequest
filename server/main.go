package main

import (
	"database/sql"
	"log"
	"net/http"
	"time"
)

// version is stamped at build time: go build -ldflags "-X main.version=1.2.3"
var version = "dev"

func main() {
	loadConfig() // system SMTP/SMS/phone providers from config.json or env SMTP_*

	db, err := openDB()
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer db.Close()

	if err := runMigrations(db); err != nil {
		log.Fatalf("migrate: %v", err)
	}

	go runScheduler(db)

	log.Println("bequest server listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", newMux(db)))
}

// runScheduler ticks the dead-man's-switch scan every 60s.
func runScheduler(db *sql.DB) {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		scan(db, time.Now())
	}
}

func newMux(db *sql.DB) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("POST /api/v1/auth/register", handleRegister(db))
	mux.HandleFunc("POST /api/v1/auth/login", handleLogin(db))
	mux.Handle("GET /api/v1/me", requireAuth(handleMe(db)))
	mux.Handle("GET /api/v1/categories", requireAuth(handleListCategories(db)))
	mux.Handle("POST /api/v1/categories", requireAuth(handleCreateCategory(db)))
	mux.Handle("DELETE /api/v1/categories/{id}", requireAuth(handleDeleteCategory(db)))
	mux.Handle("GET /api/v1/assets", requireAuth(handleListAssets(db)))
	mux.Handle("GET /api/v1/assets/{id}", requireAuth(handleGetAsset(db)))
	mux.Handle("POST /api/v1/assets", requireAuth(handleCreateAsset(db)))
	mux.Handle("PUT /api/v1/assets/{id}", requireAuth(handleUpdateAsset(db)))
	mux.Handle("DELETE /api/v1/assets/{id}", requireAuth(handleDeleteAsset(db)))
	mux.Handle("GET /api/v1/inheritors", requireAuth(handleListInheritors(db)))
	mux.Handle("POST /api/v1/inheritors", requireAuth(handleCreateInheritor(db)))
	mux.Handle("PUT /api/v1/inheritors/{id}", requireAuth(handleUpdateInheritor(db)))
	mux.Handle("DELETE /api/v1/inheritors/{id}", requireAuth(handleDeleteInheritor(db)))
	mux.Handle("GET /api/v1/reminder-templates", requireAuth(handleListTemplates(db)))
	mux.Handle("POST /api/v1/reminder-templates", requireAuth(handleCreateTemplate(db)))
	mux.Handle("PUT /api/v1/reminder-templates/{id}", requireAuth(handleUpdateTemplate(db)))
	mux.Handle("DELETE /api/v1/reminder-templates/{id}", requireAuth(handleDeleteTemplate(db)))
	mux.Handle("GET /api/v1/reminders", requireAuth(handleListReminders(db)))
	mux.Handle("POST /api/v1/reminders/{id}/read", requireAuth(handleMarkReminderRead(db)))
	mux.HandleFunc("POST /api/v1/inheritance/claim", handleClaim(db))
	mux.Handle("GET /api/v1/inheritance/status", requireAuth(handleInheritanceStatus(db)))
	mux.Handle("GET /api/v1/audit-log", requireAuth(handleAuditLog(db)))
	mux.Handle("GET /api/v1/settings/smtp", requireAuth(handleGetSMTP(db)))
	mux.Handle("PUT /api/v1/settings/smtp", requireAuth(handlePutSMTP(db)))
	mux.Handle("DELETE /api/v1/settings/smtp", requireAuth(handleDeleteSMTP(db)))
	mux.HandleFunc("GET /api/v1/version", handleVersion)
	return mux
}
