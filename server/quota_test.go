package main

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// createAsset posts one valid asset and returns the recorder.
func createAsset(t *testing.T, ts *httptest.Server, token, name string) *httptest.ResponseRecorder {
	t.Helper()
	body := fmt.Sprintf(`{"name":%q,"asset_type":"virtual","encrypted_data":%q}`, name,
		base64.StdEncoding.EncodeToString([]byte("secret-"+name)))
	return doReq(t, ts, http.MethodPost, "/api/v1/assets", body, token)
}

// TestFreeTierAssetQuota: a free user can create exactly 50 assets.
func TestFreeTierAssetQuota(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")

	for i := 0; i < 50; i++ {
		if rr := createAsset(t, ts, token, fmt.Sprintf("asset-%02d", i)); rr.Code != http.StatusCreated {
			t.Fatalf("asset %d: status=%d want 201 body=%s", i, rr.Code, rr.Body.String())
		}
	}
}

// TestFreeTierAssetQuotaExceeded: the 51st asset is rejected with the exact message.
func TestFreeTierAssetQuotaExceeded(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")

	for i := 0; i < 50; i++ {
		if rr := createAsset(t, ts, token, fmt.Sprintf("asset-%02d", i)); rr.Code != http.StatusCreated {
			t.Fatalf("asset %d: status=%d want 201 body=%s", i, rr.Code, rr.Body.String())
		}
	}
	rr := createAsset(t, ts, token, "asset-51")
	if rr.Code != http.StatusForbidden {
		t.Fatalf("51st asset: status=%d want 403 body=%s", rr.Code, rr.Body.String())
	}
	want := `{"error":"免费用户最多 50 条资产,升级会员可解锁"}`
	if strings.TrimSpace(rr.Body.String()) != want {
		t.Fatalf("51st asset body=%s want %s", rr.Body.String(), want)
	}
}

// TestMemberTierAssetNoQuota: members have no asset limit.
func TestMemberTierAssetNoQuota(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")
	if _, err := db.Exec(`UPDATE users SET tier = 'member' WHERE id = ?`, uid); err != nil {
		t.Fatalf("set tier member: %v", err)
	}

	for i := 0; i < 51; i++ {
		if rr := createAsset(t, ts, token, fmt.Sprintf("asset-%02d", i)); rr.Code != http.StatusCreated {
			t.Fatalf("member asset %d: status=%d want 201 body=%s", i, rr.Code, rr.Body.String())
		}
	}
}

// TestFreeTierQuotaNotShared: the quota is per-user, not global.
func TestFreeTierQuotaNotShared(t *testing.T) {
	ts, _ := newTestServer(t)
	tokenA := registerUser(t, ts, "alice")
	tokenB := registerUser(t, ts, "bob")

	for i := 0; i < 50; i++ {
		if rr := createAsset(t, ts, tokenA, fmt.Sprintf("a-%02d", i)); rr.Code != http.StatusCreated {
			t.Fatalf("A asset %d: status=%d want 201 body=%s", i, rr.Code, rr.Body.String())
		}
	}
	if rr := createAsset(t, ts, tokenA, "a-51"); rr.Code != http.StatusForbidden {
		t.Fatalf("A 51st: status=%d want 403 body=%s", rr.Code, rr.Body.String())
	}
	// B is a separate free user: still below quota.
	if rr := createAsset(t, ts, tokenB, "b-1"); rr.Code != http.StatusCreated {
		t.Fatalf("B first asset: status=%d want 201 body=%s", rr.Code, rr.Body.String())
	}
}
