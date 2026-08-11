package main

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// webDir returns the Flutter web build directory to serve, or "" to disable.
// Order: $WEB_DIR env > ./web (repo checkout: app/build/web) > disabled.
func webDir() string {
	if d := os.Getenv("WEB_DIR"); d != "" {
		return d
	}
	for _, candidate := range []string{"web", "app/build/web", "../app/build/web"} {
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			return candidate
		}
	}
	return ""
}

// spaHandler serves the Flutter web build (SPA): real files as-is,
// unknown paths fall back to index.html so client-side routes work.
func spaHandler(dir string) http.Handler {
	fs := http.FileServer(http.Dir(dir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// API 路径不参与 SPA 回退:未匹配路由应 404,而非返回 index.html。
		if strings.HasPrefix(r.URL.Path, "/api/") {
			http.NotFound(w, r)
			return
		}
		// Clean path must resolve to an existing regular file under dir.
		p := filepath.Join(dir, filepath.FromSlash(r.URL.Path))
		if info, err := os.Stat(p); err == nil && !info.IsDir() {
			fs.ServeHTTP(w, r)
			return
		}
		// SPA fallback: serve index.html for unmatched paths.
		http.ServeFile(w, r, filepath.Join(dir, "index.html"))
	})
}
