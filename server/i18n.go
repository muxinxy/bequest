package main

// Server-side localization (zh/en).
//
// HTTP API error messages and audit/notify copy are written in Chinese
// throughout the codebase. To support English clients without rewriting every
// call site, this file adds:
//
//   - langOf: resolves the client language from the Accept-Language header.
//   - writeError localization: writeError translates its Chinese message
//     through errEn when the request's language is English.
//   - userLang: reads the per-user language preference (users.lang, column
//     added by migration 025; default "zh") from the user id.
//   - userMsg localization: userMsg translates Chinese user-facing copy
//     (scheduler reminders, mail subjects/bodies, reset-password copy) through
//     userMsgEn when the recipient user's language is English.
//
// A tiny middleware (localize) stores the resolved language on a wrapper of
// the ResponseWriter so writeError can read it without changing its
// signature. Non-HTTP code paths (scheduler mail/reminders) pick their
// language from the recipient user's stored preference.

import (
	"database/sql"
	"net/http"
	"strings"
)

// langKey is the interface a ResponseWriter wrapper may implement to expose
// the resolved request language.
type langKey interface {
	ResponseLang() string // "zh" or "en"
}

// langWriter wraps http.ResponseWriter and remembers the request language.
type langWriter struct {
	http.ResponseWriter
	lang string
}

func (w *langWriter) ResponseLang() string { return w.lang }

// localize resolves the request language from Accept-Language and wraps w so
// writeError can localize messages. Defaults to "zh" when absent.
func localize(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lang := "zh"
		if h := r.Header.Get("Accept-Language"); h != "" {
			if strings.Contains(strings.ToLower(h), "en") {
				lang = "en"
			}
		}
		next.ServeHTTP(&langWriter{ResponseWriter: w, lang: lang}, r)
	})
}

// responseLang extracts the request language from a ResponseWriter wrapper.
// Returns "" when not wrapped (defaults to Chinese by callers).
func responseLang(w http.ResponseWriter) string {
	if lw, ok := w.(langKey); ok {
		return lw.ResponseLang()
	}
	return ""
}

// errEn maps Chinese error messages to English. Keys must match the literal
// strings passed to writeError across the codebase; untranslated strings pass
// through as Chinese (safe degradation). fmt.Sprintf'd messages with format
// verbs (%d etc.) are translated by errEnFmt via the same map keyed on the
// Chinese format string.
var errEn = map[string]string{
	// middleware / auth
	"缺少 Bearer 令牌":           "Missing Bearer token",
	"无效或已过期的令牌":              "Invalid or expired token",
	"账号已被禁用":                 "Account disabled",
	"需要管理员权限":                "Administrator privileges required",
	"用户已不存在":                 "User no longer exists",
	"用户名或密码错误":               "Incorrect username or password",
	"验证码错误或已过期":              "Incorrect or expired captcha",
	"验证码错误":                  "Incorrect captcha",
	"无效的验证码":                 "Invalid captcha",
	"无效或已过期的验证码":             "Invalid or expired verification code",
	"尝试次数过多,账号已锁定,请 5 分钟后再试": "Too many attempts; account locked for 5 minutes",
	"尝试次数过多,请重新获取验证码":        "Too many attempts; please request a new code",
	"尝试次数过多,请稍后再试":           "Too many attempts, please try again later",
	"请求过于频繁,请稍后再试":           "Too many requests, please try again later",
	"用户名和密码必填":               "Username and password are required",
	"密码至少 8 个字符":             "Password must be at least 8 characters",
	"邮箱必须包含 @":               "Email must contain @",
	"用户名必填":                  "Username is required",
	"邮箱必填":                   "Email is required",
	"名称必填":                   "Name is required",
	"用户名或邮箱已被占用":             "Username or email already taken",
	"当前密码错误":                 "Current password is incorrect",
	"密码错误":                   "Incorrect password",
	"请求格式错误":                 "Malformed request",
	"请求数据格式错误":               "Malformed request body",
	"服务器内部错误":                "Internal server error",
	"数据库不可用":                 "Database unavailable",
	// captcha / rate limit
	"请求过于频繁": "Too many requests",
	"无效的邮箱":  "Invalid email",
	// generic validators
	"无效的 ID":         "Invalid ID",
	"无效的 ID 列表":      "Invalid ID list",
	"无效的 limit":      "Invalid limit",
	"无效的 offset":     "Invalid offset",
	"无效的 page":       "Invalid page",
	"无效的 page_size":  "Invalid page size",
	"无效的状态":          "Invalid status",
	"无效的语言":          "Invalid language",
	"无效的用户 ID":       "Invalid user ID",
	"无效的继承人 ID":      "Invalid inheritor ID",
	"无效的兑换码 ID":      "Invalid redemption code ID",
	"无效的项目类型":        "Invalid item type",
	"无效的 move_to 参数": "Invalid move_to parameter",
	"请提供 ID 列表":      "An ID list is required",
	"没有可更新的字段":       "No updatable fields",
	"没有需要更新的内容":      "Nothing to update",
	// resources
	"资产不存在": "Asset not found",
	"资产类型必须为 physical 或 virtual": "Asset type must be physical or virtual",
	"资产数量过多":                     "Too many assets",
	"资产密钥缺失":                     "Missing asset key",
	"分组不存在":                      "Category not found",
	"分组已存在":                      "Category already exists",
	"目标分组不存在":                    "Target category not found",
	"已被使用不可删除":                   "In use and cannot be deleted",
	"继承人不存在":                     "Inheritor not found",
	"继承人不存在或不属于该用户":              "Inheritor not found or does not belong to this user",
	"该继承人已绑定此资产":                 "This inheritor is already bound to this asset",
	"该继承人已绑定此分组":                 "This inheritor is already bound to this category",
	"无效的继承人":                     "Invalid inheritor",
	"绑定关系不存在":                    "Binding not found",
	"提醒不存在":                      "Reminder not found",
	"提醒模板不存在":                    "Reminder template not found",
	"模板类型不合法":                    "Invalid template type",
	"触发阶梯不存在":                    "Trigger ladder not found",
	"无效的触发阶梯":                    "Invalid trigger ladder",
	"全局阶梯无需解绑":                   "Global ladder cannot be unbound",
	"回收站项目不存在":                   "Recycle bin item not found",
	"兑换码不存在":                     "Redemption code not found",
	"兑换码不能为空":                    "Redemption code is required",
	"兑换码无效或已被使用":                 "Redemption code invalid or already used",
	"短信提供商不存在":                   "SMS provider not found",
	"用户不存在":                      "User not found",
	// admin
	"不能删除自己":                "Cannot delete yourself",
	"不能降级或禁用自己":             "Cannot demote or disable yourself",
	"不能删除最后一个管理员":           "Cannot delete the last administrator",
	"角色必须为 user 或 admin":    "Role must be user or admin",
	"会员等级必须为 free 或 member": "Tier must be free or member",
	"管理后台页面缺失":              "Admin page missing",
	"领取页面缺失":                "Claim page missing",
	"无法写入 config.json":      "Cannot write config.json",
	// smtp / channels / misc
	"主机必填":             "Host is required",
	"端口必须在 1-65535 之间": "Port must be between 1 and 65535",
	"首次配置必须提供密码":       "Password is required on first configuration",
	"名称必填,邮箱或手机号至少填一个": "Name is required; provide at least one email or phone",
	"手机号功能为会员专属":       "Phone notifications are a member feature",
	"时长须在 1-3650 天之间":  "Duration must be between 1 and 3650 days",
	"数量须在 1-100 之间":    "Quantity must be between 1 and 100",
	// claim / inheritance
	"无效的 event_key 或访问码": "Invalid event key or access code",
	"交接事件已被领取或已撤销":       "This event has already been claimed or reversed",
	// quota
	"免费用户最多 %d 条资产,升级会员可解锁": "Free users are limited to %d assets; upgrade to member to unlock more",
	"自定义提醒模板为会员功能":          "Custom reminder templates are a member feature",
}

// translateErr returns the English message for a Chinese error message, or
// the original when no translation exists / the language is Chinese.
func translateErr(lang, msg string) string {
	if lang != "en" {
		return msg
	}
	if s, ok := errEn[msg]; ok {
		return s
	}
	return msg
}

// userLang returns the user's stored language preference ("zh"/"en"),
// defaulting to "zh" on lookup errors / empty values.
func userLang(db *sql.DB, uid int64) string {
	var lang string
	if err := db.QueryRow(`SELECT lang FROM users WHERE id = ?`, uid).Scan(&lang); err != nil || lang == "" {
		return "zh"
	}
	return lang
}

// userMsgEn maps Chinese user-facing copy (scheduler reminders, mail subjects/
// bodies, password-reset copy) to English. Keys must match the literals passed
// to userMsg across the codebase; untranslated strings pass through as Chinese
// (safe degradation). String literals carrying %s/%d verbs are translated
// through the same map keyed on the Chinese format string.
var userMsgEn = map[string]string{
	// notify.go / preset escalation template fallbacks
	"长时间未登录提醒":             "Long inactivity reminder",
	"您已 %d 天未登录,资产安全提醒升级。": "You have not logged in for %d days. Your asset safety alert has been escalated.",
	// scheduler.go / preset expiry template fallbacks
	"资产「%s」即将到期": "Asset \"%s\" is expiring soon",
	"您的资产 %s 将于 %s 到期,剩余 %d 天,请及时处理续费或迁移。": "Your asset %s expires on %s (%d days left). Please renew or migrate it in time.",
	"资产「%s」已到期": "Asset \"%s\" has expired",
	"您的资产 %s 已于 %s 到期,请及时处理续费或迁移。": "Your asset %s expired on %s. Please renew or migrate it in time.",
	// scheduler.go / preset inheritance template fallbacks + inheritor email
	"继承交接已触发":        "Inheritance handover triggered",
	"继承交接已触发,事件密钥: ": "Inheritance handover triggered, event key: ",
	" (资产: ":         " (asset: ",
	"继承交接已触发。事件密钥: %s\n请通过 App/API 使用该密钥与您的访问码完成继承领取。": "Inheritance handover has been triggered. Event key: %s\nUse this key with your access code in the App/API to claim the inheritance.",
	// auth_ext.go / password-reset email (subject part after the "托孤: " prefix + body)
	"重置密码验证码": "Password reset code",
	"您的验证码是: %s\n10 分钟内有效。若非本人操作请忽略。": "Your verification code is: %s\nIt is valid for 10 minutes. Ignore this email if you did not request it.",
}

// userMsg returns the user-facing message for lang: the English translation
// when lang is "en" and one exists, otherwise the Chinese original.
func userMsg(lang, zh string) string {
	if lang != "en" {
		return zh
	}
	if s, ok := userMsgEn[zh]; ok {
		return s
	}
	return zh
}

// parseLangFromHeader is a tiny helper for tests.
func parseLangFromHeader(h string) string {
	if h == "" {
		return "zh"
	}
	if strings.Contains(strings.ToLower(h), "en") {
		return "en"
	}
	return "zh"
}
