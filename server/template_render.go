package main

import (
	"database/sql"
	"strings"
)

// ---------- 提醒模板渲染 ----------

// renderTemplate 按类型取模板并渲染标题/正文:
// 1. 会员优先用自定义模板(user_id=uid AND type=rtype);
// 2. 否则用系统预设模板(user_id IS NULL AND type=rtype);
// 3. 都没有则返回空串,调用方回退硬编码文案。
// 免费用户跳过自定义模板(预设模板已可用)。
func renderTemplate(db *sql.DB, uid int64, rtype string, vars map[string]string) (title, body string) {
	var tier string
	if err := db.QueryRow(`SELECT tier FROM users WHERE id = ?`, uid).Scan(&tier); err != nil {
		tier = "free"
	}
	if tier == "member" {
		var t, b string
		if err := db.QueryRow(`SELECT title_template, body_template FROM reminder_templates
			WHERE user_id = ? AND type = ?`, uid, rtype).Scan(&t, &b); err == nil {
			return renderVars(t, vars), renderVars(b, vars)
		}
	}
	var t, b string
	if err := db.QueryRow(`SELECT title_template, body_template FROM reminder_templates
		WHERE user_id IS NULL AND type = ?`, rtype).Scan(&t, &b); err == nil {
		return renderVars(t, vars), renderVars(b, vars)
	}
	return "", ""
}

// renderVars 把 {name}/{date}/{days} 等占位符替换为 vars 对应值;缺失变量留空。
func renderVars(s string, vars map[string]string) string {
	for k, v := range vars {
		s = strings.ReplaceAll(s, "{"+k+"}", v)
	}
	return s
}