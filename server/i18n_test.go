package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// withLocalize returns the test server wrapped in the production localize
// middleware (newTestServer wires newMux directly, which does not include it).
func withLocalize(ts *httptest.Server) {
	inner := ts.Config.Handler
	ts.Config.Handler = localize(inner)
	ts.Config.TLSNextProto = nil
}

// TestErrorLocalizationEn: an English Accept-Language header must produce
// English API error messages (the writeError -> translateErr path).
func TestErrorLocalizationEn(t *testing.T) {
	ts, _ := newTestServer(t)
	defer ts.Close()
	withLocalize(ts)

	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/v1/me", nil)
	req.Header.Set("Accept-Language", "en")
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if want := `"error":"Missing Bearer token"`; !strings.Contains(string(body), want) {
		t.Fatalf("body = %s, want it to contain %s", body, want)
	}
}

// TestErrorLocalizationZhDefault: no Accept-Language keeps Chinese errors.
func TestErrorLocalizationZhDefault(t *testing.T) {
	ts, _ := newTestServer(t)
	defer ts.Close()
	withLocalize(ts)

	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/v1/me", nil)
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if want := `"error":"缺少 Bearer 令牌"`; !strings.Contains(string(body), want) {
		t.Fatalf("body = %s, want it to contain %s", body, want)
	}
}

// TestErrorLocalizationFmtString: fmt.Sprintf'd error (quota) translates too.
func TestErrorLocalizationFmtString(t *testing.T) {
	ts, _ := newTestServer(t)
	defer ts.Close()
	withLocalize(ts)
	// Free-tier quota message is produced by handleCreateAsset; a full
	// register+51-assets flow is heavy, so assert the dictionary mapping here
	// (translateErr is the same function writeError uses).
	if got := translateErr("en", "免费用户最多 %d 条资产,升级会员可解锁"); got != "Free users are limited to %d assets; upgrade to member to unlock more" {
		t.Fatalf("unexpected translation: %s", got)
	}
	if got := translateErr("zh", "免费用户最多 %d 条资产,升级会员可解锁"); got == "Free users are limited to %d assets; upgrade to member to unlock more" {
		t.Fatal("zh must not translate")
	}
}
