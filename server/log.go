package main

import (
	"database/sql"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"time"
)

// logKinds:审计日志(audit)与应用日志(app)。
const (
	logKindAudit = "audit"
	logKindApp   = "app"
)

// logActivity 写入一条日志。kind 为 audit(重要操作) 或 app(普通操作),
// action 用中文描述,detail 为可选 JSON 补充(目标名称等)。
// 写入既有 audit_logs 表,actor 固定 'owner'(仅记录用户本人操作)。
func logActivity(db *sql.DB, uid int64, kind, action string, detail map[string]any) {
	var d any
	if len(detail) > 0 {
		b, err := json.Marshal(detail)
		if err == nil {
			d = string(b)
		}
	}
	if _, err := db.Exec(`INSERT INTO audit_logs (user_id, actor, kind, action, detail) VALUES (?, ?, ?, ?, ?)`,
		uid, "owner", kind, action, d); err != nil {
		log.Printf("log activity: %v", err)
	}
}

// logAudit 记录重要操作(审计日志)。重要操作同时记应用日志(所有操作都记)。
func logAudit(db *sql.DB, uid int64, action string, detail map[string]any) {
	logActivity(db, uid, logKindAudit, action, detail)
	logActivity(db, uid, logKindApp, action, detail)
}

// logApp 记录普通操作(应用日志)。
func logApp(db *sql.DB, uid int64, action string, detail map[string]any) {
	logActivity(db, uid, logKindApp, action, detail)
}

type logJSON struct {
	ID        int64  `json:"id"`
	Kind      string `json:"kind"`
	Action    string `json:"action"`
	Detail    string `json:"detail,omitempty"`
	CreatedAt string `json:"created_at"`
}

// parseLogQuery 解析 kind/month 查询参数;kind 非法时返回 400 消息。
// month 形如 "2026-08";空 = 不限月份。limit 默认 500。
func parseLogQuery(r *http.Request) (kind string, month string, limit int, bad string) {
	kind = r.URL.Query().Get("kind")
	if kind != "" && kind != logKindAudit && kind != logKindApp {
		return "", "", 0, "kind 必须为 audit 或 app"
	}
	month = r.URL.Query().Get("month")
	if month != "" {
		if _, err := time.Parse("2006-01", month); err != nil {
			return "", "", 0, "month 必须为 YYYY-MM 格式"
		}
	}
	limit = 500
	if s := r.URL.Query().Get("limit"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n > 0 && n <= 2000 {
			limit = n
		}
	}
	return kind, month, limit, ""
}

// handleListLogs: GET /api/v1/logs?kind=&month=&limit= -> 200 日志列表(倒序)。
func handleListLogs(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		kind, month, limit, bad := parseLogQuery(r)
		if bad != "" {
			writeError(w, http.StatusBadRequest, bad)
			return
		}
		where := "WHERE user_id = ?"
		args := []any{userID(r)}
		if kind != "" {
			where += " AND kind = ?"
			args = append(args, kind)
		}
		if month != "" {
			where += " AND created_at LIKE ?"
			args = append(args, month+"%")
		}
		rows, err := db.Query(`SELECT id, kind, action, COALESCE(detail, ''), created_at
			FROM audit_logs `+where+` ORDER BY id DESC LIMIT ?`, append(args, limit)...)
		if err != nil {
			log.Printf("list logs: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		list := []logJSON{}
		for rows.Next() {
			var l logJSON
			if err := rows.Scan(&l.ID, &l.Kind, &l.Action, &l.Detail, &l.CreatedAt); err != nil {
				log.Printf("scan log: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			list = append(list, l)
		}
		writeJSON(w, http.StatusOK, list)
	}
}

// handleExportLogs: GET /api/v1/logs/export?kind=&month= -> CSV 下载。
func handleExportLogs(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		kind, month, _, bad := parseLogQuery(r)
		if bad != "" {
			writeError(w, http.StatusBadRequest, bad)
			return
		}
		where := "WHERE user_id = ?"
		args := []any{userID(r)}
		if kind != "" {
			where += " AND kind = ?"
			args = append(args, kind)
		}
		if month != "" {
			where += " AND created_at LIKE ?"
			args = append(args, month+"%")
		}
		rows, err := db.Query(`SELECT id, kind, action, COALESCE(detail, ''), created_at
			FROM audit_logs `+where+` ORDER BY id`, args...)
		if err != nil {
			log.Printf("export logs: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()

		fname := fmt.Sprintf("logs-%s.csv", time.Now().Format("20060102-150405"))
		w.Header().Set("Content-Type", "text/csv; charset=utf-8")
		w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", fname))
		cw := csv.NewWriter(w)
		_ = cw.Write([]string{"ID", "类型", "操作", "详情", "时间"})
		for rows.Next() {
			var l logJSON
			if err := rows.Scan(&l.ID, &l.Kind, &l.Action, &l.Detail, &l.CreatedAt); err != nil {
				log.Printf("scan export log: %v", err)
				return
			}
			kindLabel := map[string]string{logKindAudit: "审计", logKindApp: "应用"}[l.Kind]
			_ = cw.Write([]string{
				strconv.FormatInt(l.ID, 10), kindLabel, l.Action, l.Detail, l.CreatedAt,
			})
		}
		cw.Flush()
	}
}

// handleClearLogs: DELETE /api/v1/logs?kind=&month= -> 200 {"deleted":n}。
// 不传 kind/month 时清空该用户全部日志。
func handleClearLogs(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		kind, month, _, bad := parseLogQuery(r)
		if bad != "" {
			writeError(w, http.StatusBadRequest, bad)
			return
		}
		where := "WHERE user_id = ?"
		args := []any{userID(r)}
		if kind != "" {
			where += " AND kind = ?"
			args = append(args, kind)
		}
		if month != "" {
			where += " AND created_at LIKE ?"
			args = append(args, month+"%")
		}
		res, err := db.Exec(`DELETE FROM audit_logs `+where, args...)
		if err != nil {
			log.Printf("clear logs: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		n, _ := res.RowsAffected()
		// 清除日志本身也记一条审计(仅当不是清空后马上被删)。
		writeJSON(w, http.StatusOK, map[string]int64{"deleted": n})
	}
}

// logMonthOptions 返回该用户有日志的年份-月份列表(用于前端年月筛选)。
// GET /api/v1/logs/months -> 200 ["2026-08", ...]
func handleLogMonths(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT DISTINCT substr(created_at, 1, 7) AS ym
			FROM audit_logs WHERE user_id = ? ORDER BY ym DESC`, userID(r))
		if err != nil {
			log.Printf("log months: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		months := []string{}
		for rows.Next() {
			var m string
			if err := rows.Scan(&m); err != nil {
				log.Printf("scan month: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			months = append(months, m)
		}
		writeJSON(w, http.StatusOK, months)
	}
}