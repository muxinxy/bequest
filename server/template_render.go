package main

import (
	"database/sql"
	"strings"
)

// ---------- 提醒模板渲染 ----------

// renderTemplate 按类型取模板并渲染标题/正文:
//  1. 会员优先用自定义模板:先取 is_default=1 的默认模板;
//     若无默认,回退该类型 id 最小的自定义模板(首个创建,与"首个自动默认"一致);
//  2. 否则用系统预设模板(user_id IS NULL AND type=rtype);
//  3. 都没有则返回空串,调用方回退硬编码文案。
//
// 免费用户跳过自定义模板(预设模板已可用)。
func renderTemplate(db *sql.DB, uid int64, rtype string, vars map[string]string) (title, body string) {
	var tier string
	if err := db.QueryRow(`SELECT tier FROM users WHERE id = ?`, uid).Scan(&tier); err != nil {
		tier = "free"
	}
	if tier == "member" {
		var t, b string
		if err := db.QueryRow(`SELECT title_template, body_template FROM reminder_templates
			WHERE user_id = ? AND type = ? AND is_default = 1`, uid, rtype).Scan(&t, &b); err == nil {
			return renderVars(t, vars), renderVars(b, vars)
		}
		// 无默认标记时回退首个自定义模板(存量数据未回填默认)。
		if err := db.QueryRow(`SELECT title_template, body_template FROM reminder_templates
			WHERE user_id = ? AND type = ? ORDER BY id LIMIT 1`, uid, rtype).Scan(&t, &b); err == nil {
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
