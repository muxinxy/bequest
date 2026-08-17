package main

import (
	"net"
	"net/http"
	"sync"
	"time"
)

// ---------- 按 IP 频率限制(内存滑动窗口) ----------
// 登录/注册/继承领取/2FA:5 次/分钟/IP;其他 API:300 次/分钟/IP。
// 单机内存计数;多实例部署需换共享存储(本项目单二进制,足够)。

type rateWindow struct {
	counts []time.Time
	limit  int
	window time.Duration
}

type ipLimiter struct {
	mu   sync.Mutex
	auth map[string]*rateWindow // 登录/注册等敏感端点
	api  map[string]*rateWindow // 常规 API
}

var globalLimiter = &ipLimiter{
	auth: map[string]*rateWindow{},
	api:  map[string]*rateWindow{},
}

const (
	authLimit  = 5
	authWindow = time.Minute
	apiLimit   = 300
	apiWindow  = time.Minute
)

func clientIP(r *http.Request) string {
	// 优先 X-Forwarded-For(反代后),否则 RemoteAddr。
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := indexByte(xff, ','); i >= 0 {
			return trimSpace(xff[:i])
		}
		return trimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func indexByte(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}

func trimSpace(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
		s = s[:len(s)-1]
	}
	return s
}

// allow records a hit and reports whether the IP is within limit.
func (l *ipLimiter) allow(m map[string]*rateWindow, ip string, limit int, window time.Duration) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	w, ok := m[ip]
	if !ok {
		m[ip] = &rateWindow{limit: limit, window: window}
		w = m[ip]
	}
	now := time.Now()
	cutoff := now.Add(-window)
	kept := w.counts[:0]
	for _, t := range w.counts {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	w.counts = append(kept, now)
	return len(w.counts) <= limit
}

// reset removes stale entries to avoid unbounded growth.
func (l *ipLimiter) reset() {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	for ip, w := range l.auth {
		if len(w.counts) == 0 || now.Sub(w.counts[len(w.counts)-1]) > w.window {
			delete(l.auth, ip)
		}
	}
	for ip, w := range l.api {
		if len(w.counts) == 0 || now.Sub(w.counts[len(w.counts)-1]) > w.window {
			delete(l.api, ip)
		}
	}
}

// rateLimit middleware: sensitive auth endpoints get a stricter window.
func rateLimit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		globalLimiter.reset()
		ip := clientIP(r)
		isAuth := r.URL.Path == "/api/v1/auth/login" ||
			r.URL.Path == "/api/v1/auth/register" ||
			r.URL.Path == "/api/v1/auth/2fa/verify" ||
			r.URL.Path == "/api/v1/auth/reset-request" ||
			r.URL.Path == "/api/v1/auth/reset" ||
			r.URL.Path == "/api/v1/inheritance/claim"
		allowed := globalLimiter.allow(globalLimiter.api, ip, apiLimit, apiWindow)
		if isAuth {
			// 严格限制叠加:登录/注册也计入常规窗口,但独立计数更紧。
			allowed = globalLimiter.allow(globalLimiter.auth, ip, authLimit, authWindow)
		}
		if !allowed {
			writeError(w, http.StatusTooManyRequests, "请求过于频繁,请稍后再试")
			return
		}
		next.ServeHTTP(w, r)
	})
}
