package main

import (
	"database/sql"
	"log"
	"net/http"
	"os"
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

	// 备份子命令:VACUUM INTO 生成一致性快照(含 WAL 数据,可直接冷启动)。
	if len(os.Args) > 1 && os.Args[1] == "backup" {
		out := "bequest-backup-" + time.Now().Format("20060102-150405") + ".db"
		if _, err := db.Exec("VACUUM INTO '" + out + "'"); err != nil {
			log.Fatalf("backup: %v", err)
		}
		log.Printf("backup written to %s", out)
		return
	}

	ensureAdmin(db) // ADMIN_USERNAME/ADMIN_PASSWORD bootstrap (if set)

	go runScheduler(db)

	addr := ":8080"
	if p := os.Getenv("PORT"); p != "" {
		addr = ":" + p
	}
	log.Printf("bequest server listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, cors(rateLimit(newMux(db)))))
}

// runScheduler ticks the dead-man's-switch scan every 60s; pruneLogs runs
// once at startup and then every 24h.
func runScheduler(db *sql.DB) {
	pruneLogs(db)
	lastPrune := time.Now()
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	for now := range ticker.C {
		scan(db, now)
		if now.Sub(lastPrune) >= 24*time.Hour {
			pruneLogs(db)
			lastPrune = now
		}
	}
}

func newMux(db *sql.DB) *http.ServeMux {
	mux := http.NewServeMux()
	// 探活:查 DB 可达性(容器探活据此判断健康,而非只看进程在)。
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		if err := db.PingContext(r.Context()); err != nil {
			writeError(w, http.StatusServiceUnavailable, "数据库不可用")
			return
		}
		w.Write([]byte("ok"))
	})
	// 管理后台(内嵌单页,无需构建)。
	mux.HandleFunc("GET /admin", serveAdminPage)
	mux.HandleFunc("GET /admin/", serveAdminPage)
	// 继承人交接领取页(无鉴权;领取校验在 claim API)。
	mux.HandleFunc("GET /claim", serveClaimPage)
	mux.HandleFunc("GET /claim/", serveClaimPage)
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
	mux.HandleFunc("POST /api/v1/auth/2fa/verify", handleVerify2FA(db))
	mux.Handle("PUT /api/v1/me", auth(handleUpdateProfile(db)))
	mux.Handle("PUT /api/v1/me/password", auth(handleChangePassword(db)))
	mux.Handle("GET /api/v1/me", auth(handleMe(db)))
	// 会员兑换码。
	mux.Handle("POST /api/v1/membership/redeem", auth(handleRedeemMembership(db)))
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
	mux.Handle("PUT /api/v1/assets/{id}/inheritors/{iid}", auth(handleUpdateAssetInheritorLadder(db)))
	mux.Handle("DELETE /api/v1/assets/{id}/inheritors/{iid}", auth(handleDeleteAssetInheritor(db)))
	mux.Handle("GET /api/v1/categories/{id}/inheritors", auth(handleListCategoryInheritors(db)))
	mux.Handle("POST /api/v1/categories/{id}/inheritors", auth(handleCreateCategoryInheritor(db)))
	mux.Handle("PUT /api/v1/categories/{id}/inheritors/{iid}", auth(handleUpdateCategoryInheritorLadder(db)))
	mux.Handle("DELETE /api/v1/categories/{id}/inheritors/{iid}", auth(handleDeleteCategoryInheritor(db)))
	mux.Handle("GET /api/v1/categories/{id}/inheritors/{iid}/assets", auth(handleListCategoryInheritorAssets(db)))
	// 触发阶梯。
	mux.Handle("GET /api/v1/trigger-ladders", auth(handleListTriggerLadders(db)))
	mux.Handle("POST /api/v1/trigger-ladders", auth(handleCreateTriggerLadder(db)))
	mux.Handle("PUT /api/v1/trigger-ladders/{id}", auth(handleUpdateTriggerLadder(db)))
	mux.Handle("DELETE /api/v1/trigger-ladders", auth(handleDeleteTriggerLadders(db)))
	mux.Handle("PUT /api/v1/categories/order", auth(handleReorderCategories(db)))
	mux.Handle("POST /api/v1/assets/move", auth(handleBatchMoveAssets(db)))
	mux.Handle("POST /api/v1/assets/batch-delete", auth(handleBatchDeleteAssets(db)))
	mux.Handle("POST /api/v1/assets/{id}/copy", auth(handleCopyAsset(db)))
	// 回收站。
	mux.Handle("GET /api/v1/recycle-bin", auth(handleListRecycleBin(db)))
	mux.Handle("DELETE /api/v1/recycle-bin", auth(handleEmptyRecycleBin(db)))
	mux.Handle("POST /api/v1/recycle-bin/{kind}/{id}/restore", auth(handleRestoreRecycleItem(db)))
	mux.Handle("DELETE /api/v1/recycle-bin/{kind}/{id}", auth(handlePurgeRecycleItem(db)))
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
	// 通知渠道(邮箱/手机号)。
	mux.Handle("GET /api/v1/notification-channels", auth(handleGetNotificationChannels(db)))
	mux.Handle("PUT /api/v1/notification-channels", auth(handlePutNotificationChannels(db)))
	mux.HandleFunc("POST /api/v1/inheritance/claim", handleClaim(db))
	mux.Handle("GET /api/v1/inheritance/status", auth(handleInheritanceStatus(db)))
	mux.Handle("GET /api/v1/audit-log", auth(handleAuditLog(db)))
	// 日志(审计/应用):列表按年月筛选、导出 CSV、清除。
	mux.Handle("GET /api/v1/logs", auth(handleListLogs(db)))
	mux.Handle("GET /api/v1/logs/months", auth(handleLogMonths(db)))
	mux.Handle("GET /api/v1/logs/export", auth(handleExportLogs(db)))
	mux.Handle("DELETE /api/v1/logs", auth(handleClearLogs(db)))
	mux.Handle("GET /api/v1/settings/smtp", auth(handleGetSMTP(db)))
	mux.Handle("PUT /api/v1/settings/smtp", auth(handlePutSMTP(db)))
	mux.Handle("DELETE /api/v1/settings/smtp", auth(handleDeleteSMTP(db)))
	mux.Handle("GET /api/v1/settings/inheritance", auth(handleGetInheritanceToggle(db)))
	mux.Handle("PUT /api/v1/settings/inheritance", auth(handlePutInheritanceToggle(db)))
	mux.Handle("PUT /api/v1/settings/master-key", auth(handlePutMasterKey(db)))
	mux.Handle("PUT /api/v1/settings/master-salt", auth(handlePutMasterSalt(db)))
	// 管理后台 API（requireAdmin）。
	mux.Handle("GET /api/v1/admin/stats", admin(handleAdminStats(db)))
	mux.Handle("GET /api/v1/admin/users", admin(handleAdminListUsers(db)))
	mux.Handle("GET /api/v1/admin/users/{id}", admin(handleAdminGetUser(db)))
	mux.Handle("GET /api/v1/admin/users/{id}/assets", admin(handleAdminListUserAssets(db)))
	mux.Handle("PUT /api/v1/admin/users/{id}", admin(handleAdminUpdateUser(db)))
	mux.Handle("DELETE /api/v1/admin/users/{id}", admin(handleAdminDeleteUser(db)))
	mux.Handle("GET /api/v1/admin/audit-log", admin(handleAdminAuditLog(db)))
	mux.Handle("GET /api/v1/admin/audit-log/export", admin(handleAdminAuditExport(db)))
	mux.Handle("GET /api/v1/admin/2fa", admin(handleAdmin2FAStatus(db)))
	mux.Handle("POST /api/v1/admin/2fa/setup", admin(handleAdmin2FASetup(db)))
	mux.Handle("POST /api/v1/admin/2fa/confirm", admin(handleAdmin2FAConfirm(db)))
	mux.Handle("POST /api/v1/admin/2fa/disable", admin(handleAdmin2FADisable(db)))
	mux.Handle("GET /api/v1/admin/config", admin(http.HandlerFunc(handleAdminGetConfig)))
	mux.Handle("PUT /api/v1/admin/config", admin(handleAdminPutConfig(db)))
	// 短信提供商管理。
	mux.Handle("GET /api/v1/admin/sms-providers", admin(handleAdminListSMSProviders(db)))
	mux.Handle("POST /api/v1/admin/sms-providers", admin(handleAdminCreateSMSProvider(db)))
	mux.Handle("PUT /api/v1/admin/sms-providers/{id}", admin(handleAdminUpdateSMSProvider(db)))
	mux.Handle("DELETE /api/v1/admin/sms-providers/{id}", admin(handleAdminDeleteSMSProvider(db)))
	// 兑换码管理。
	mux.Handle("GET /api/v1/admin/redemption-codes", admin(handleListRedemptionCodes(db)))
	mux.Handle("POST /api/v1/admin/redemption-codes", admin(handleCreateRedemptionCodes(db)))
	mux.Handle("DELETE /api/v1/admin/redemption-codes/{id}", admin(handleDeleteRedemptionCode(db)))
	mux.HandleFunc("GET /api/v1/version", handleVersion)
	return mux
}
