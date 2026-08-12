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

	ensureAdmin(db) // ADMIN_USERNAME/ADMIN_PASSWORD bootstrap (if set)

	go runScheduler(db)

	log.Println("bequest server listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", cors(rateLimit(newMux(db)))))
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
	// 管理后台（内嵌单页,无需构建）。
	mux.HandleFunc("GET /admin", serveAdminPage)
	mux.HandleFunc("GET /admin/", serveAdminPage)
	// Flutter web 客户端(同源托管,免 CORS);未构建 web 时静默跳过。
	if dir := webDir(); dir != "" {
		mux.Handle("GET /", spaHandler(dir))
	}
	// auth closures: requireAuth(db, h) / requireAdmin(db, h)
	auth := func(h http.Handler) http.Handler { return requireAuth(db, h) }
	admin := func(h http.Handler) http.Handler { return requireAdmin(db, h) }
	mux.HandleFunc("POST /api/v1/auth/register", handleRegister(db))
	mux.HandleFunc("POST /api/v1/auth/login", handleLogin(db))
	mux.HandleFunc("GET /api/v1/auth/captcha", handleGetCaptcha)
	mux.HandleFunc("GET /api/v1/auth/check", handleCheckUsername(db))
	mux.HandleFunc("GET /api/v1/auth/check-email", handleCheckEmail(db))
	mux.HandleFunc("POST /api/v1/auth/reset-request", handleRequestPasswordReset(db))
	mux.HandleFunc("POST /api/v1/auth/reset", handleResetPassword(db))
	mux.Handle("PUT /api/v1/me", auth(handleUpdateProfile(db)))
	mux.Handle("GET /api/v1/me", auth(handleMe(db)))
	mux.Handle("GET /api/v1/categories", auth(handleListCategories(db)))
	mux.Handle("POST /api/v1/categories", auth(handleCreateCategory(db)))
	mux.Handle("DELETE /api/v1/categories/{id}", auth(handleDeleteCategory(db)))
	mux.Handle("PUT /api/v1/categories/{id}", auth(handleUpdateCategory(db)))
	mux.Handle("GET /api/v1/assets", auth(handleListAssets(db)))
	mux.Handle("GET /api/v1/assets/{id}", auth(handleGetAsset(db)))
	mux.Handle("POST /api/v1/assets", auth(handleCreateAsset(db)))
	mux.Handle("PUT /api/v1/assets/{id}", auth(handleUpdateAsset(db)))
	mux.Handle("DELETE /api/v1/assets/{id}", auth(handleDeleteAsset(db)))
	mux.Handle("GET /api/v1/assets/{id}/inheritors", auth(handleListAssetInheritors(db)))
	mux.Handle("POST /api/v1/assets/{id}/inheritors", auth(handleCreateAssetInheritor(db)))
	mux.Handle("DELETE /api/v1/assets/{id}/inheritors/{iid}", auth(handleDeleteAssetInheritor(db)))
	mux.Handle("GET /api/v1/categories/{id}/inheritors", auth(handleListCategoryInheritors(db)))
	mux.Handle("POST /api/v1/categories/{id}/inheritors", auth(handleCreateCategoryInheritor(db)))
	mux.Handle("DELETE /api/v1/categories/{id}/inheritors/{iid}", auth(handleDeleteCategoryInheritor(db)))
	mux.Handle("GET /api/v1/inheritors/{id}/assets", auth(handleListInheritorAssets(db)))
	mux.Handle("GET /api/v1/inheritors", auth(handleListInheritors(db)))
	mux.Handle("POST /api/v1/inheritors", auth(handleCreateInheritor(db)))
	mux.Handle("PUT /api/v1/inheritors/{id}", auth(handleUpdateInheritor(db)))
	mux.Handle("DELETE /api/v1/inheritors/{id}", auth(handleDeleteInheritor(db)))
	mux.Handle("GET /api/v1/reminder-templates", auth(handleListTemplates(db)))
	mux.Handle("POST /api/v1/reminder-templates", auth(handleCreateTemplate(db)))
	mux.Handle("PUT /api/v1/reminder-templates/{id}", auth(handleUpdateTemplate(db)))
	mux.Handle("DELETE /api/v1/reminder-templates/{id}", auth(handleDeleteTemplate(db)))
	mux.Handle("GET /api/v1/reminders", auth(handleListReminders(db)))
	mux.Handle("POST /api/v1/reminders/{id}/read", auth(handleMarkReminderRead(db)))
	mux.HandleFunc("POST /api/v1/inheritance/claim", handleClaim(db))
	mux.Handle("GET /api/v1/inheritance/status", auth(handleInheritanceStatus(db)))
	mux.Handle("GET /api/v1/audit-log", auth(handleAuditLog(db)))
	mux.Handle("GET /api/v1/settings/smtp", auth(handleGetSMTP(db)))
	mux.Handle("PUT /api/v1/settings/smtp", auth(handlePutSMTP(db)))
	mux.Handle("DELETE /api/v1/settings/smtp", auth(handleDeleteSMTP(db)))
	mux.Handle("GET /api/v1/settings/inheritance", auth(handleGetInheritanceToggle(db)))
	mux.Handle("PUT /api/v1/settings/inheritance", auth(handlePutInheritanceToggle(db)))
	mux.Handle("PUT /api/v1/settings/master-key", auth(handlePutMasterKey(db)))
	// 管理后台 API（requireAdmin）。
	mux.Handle("GET /api/v1/admin/stats", admin(handleAdminStats(db)))
	mux.Handle("GET /api/v1/admin/users", admin(handleAdminListUsers(db)))
	mux.Handle("GET /api/v1/admin/users/{id}", admin(handleAdminGetUser(db)))
	mux.Handle("PUT /api/v1/admin/users/{id}", admin(handleAdminUpdateUser(db)))
	mux.Handle("DELETE /api/v1/admin/users/{id}", admin(handleAdminDeleteUser(db)))
	mux.Handle("GET /api/v1/admin/audit-log", admin(handleAdminAuditLog(db)))
	mux.Handle("GET /api/v1/admin/config", admin(http.HandlerFunc(handleAdminGetConfig)))
	mux.Handle("PUT /api/v1/admin/config", admin(handleAdminPutConfig(db)))
	mux.HandleFunc("GET /api/v1/version", handleVersion)
	return mux
}
