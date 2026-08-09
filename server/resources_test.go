package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// registerUser creates a user via the real endpoint and returns the token.
func registerUser(t *testing.T, ts *httptest.Server, username string) string {
	t.Helper()
	body := fmt.Sprintf(`{"username":%q,"email":%q,"password":"password123"}`, username, username+"@example.com")
	rr := doReq(t, ts, http.MethodPost, "/api/v1/auth/register", body, "")
	if rr.Code != http.StatusCreated {
		t.Fatalf("register %s: status=%d body=%s", username, rr.Code, rr.Body.String())
	}
	var resp struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse register response: %v", err)
	}
	return resp.Token
}

type catResp struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	CreatedAt string `json:"created_at"`
}

type assetResp struct {
	ID            int64   `json:"id"`
	Name          string  `json:"name"`
	AssetType     string  `json:"asset_type"`
	CategoryID    *int64  `json:"category_id"`
	EncryptedData string  `json:"encrypted_data"`
	ExpiryDate    *string `json:"expiry_date"`
	UpdatedAt     string  `json:"updated_at"`
}

func TestCategoryAssetFlow(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")

	// create category (name avoids the seeded presets; explicit asset_type covers the new field)
	cat := doReq(t, ts, http.MethodPost, "/api/v1/categories", `{"name":"保险","asset_type":"physical"}`, token)
	if cat.Code != http.StatusCreated {
		t.Fatalf("create category: status=%d body=%s", cat.Code, cat.Body.String())
	}
	var createdCat catResp
	if err := json.Unmarshal(cat.Body.Bytes(), &createdCat); err != nil {
		t.Fatalf("parse category: %v", err)
	}
	if createdCat.Name != "保险" || createdCat.ID == 0 {
		t.Fatalf("unexpected category: %+v", createdCat)
	}

	// duplicate category -> 409
	dup := doReq(t, ts, http.MethodPost, "/api/v1/categories", `{"name":"保险"}`, token)
	if dup.Code != http.StatusConflict {
		t.Fatalf("duplicate category: status=%d want 409 body=%s", dup.Code, dup.Body.String())
	}

	// empty name -> 400
	if rr := doReq(t, ts, http.MethodPost, "/api/v1/categories", `{"name":"   "}`, token); rr.Code != http.StatusBadRequest {
		t.Fatalf("empty name category: status=%d want 400", rr.Code)
	}

	// create asset
	payload := base64.StdEncoding.EncodeToString([]byte("secret creds for bank"))
	assetBody := fmt.Sprintf(`{"name":"银行卡","asset_type":"virtual","category_id":%d,"encrypted_data":%q,"expiry_date":"2027-12-31"}`, createdCat.ID, payload)
	asset := doReq(t, ts, http.MethodPost, "/api/v1/assets", assetBody, token)
	if asset.Code != http.StatusCreated {
		t.Fatalf("create asset: status=%d body=%s", asset.Code, asset.Body.String())
	}
	var created assetResp
	if err := json.Unmarshal(asset.Body.Bytes(), &created); err != nil {
		t.Fatalf("parse asset: %v", err)
	}
	if created.Name != "银行卡" || created.AssetType != "virtual" || created.CategoryID == nil || *created.CategoryID != createdCat.ID {
		t.Fatalf("unexpected created asset: %+v", created)
	}
	if created.EncryptedData != payload {
		t.Fatalf("encrypted_data round-trip on create: got %q want %q", created.EncryptedData, payload)
	}
	if created.ExpiryDate == nil || *created.ExpiryDate != "2027-12-31" {
		t.Fatalf("expiry_date not stored as-is: %+v", created.ExpiryDate)
	}

	// list assets -> metadata only, no encrypted_data
	list := doReq(t, ts, http.MethodGet, "/api/v1/assets", "", token)
	if list.Code != http.StatusOK {
		t.Fatalf("list assets: status=%d body=%s", list.Code, list.Body.String())
	}
	var listArr []map[string]any
	if err := json.Unmarshal(list.Body.Bytes(), &listArr); err != nil {
		t.Fatalf("parse asset list: %v", err)
	}
	if len(listArr) != 1 {
		t.Fatalf("asset list len=%d want 1: %s", len(listArr), list.Body.String())
	}
	if _, ok := listArr[0]["encrypted_data"]; ok {
		t.Fatalf("asset list must not include encrypted_data: %s", list.Body.String())
	}
	if listArr[0]["name"] != "银行卡" {
		t.Fatalf("unexpected list entry: %v", listArr[0])
	}

	// get asset -> full object, encrypted_data round-trips to original bytes
	got := doReq(t, ts, http.MethodGet, fmt.Sprintf("/api/v1/assets/%d", created.ID), "", token)
	if got.Code != http.StatusOK {
		t.Fatalf("get asset: status=%d body=%s", got.Code, got.Body.String())
	}
	var full assetResp
	if err := json.Unmarshal(got.Body.Bytes(), &full); err != nil {
		t.Fatalf("parse get asset: %v", err)
	}
	decoded, err := base64.StdEncoding.DecodeString(full.EncryptedData)
	if err != nil {
		t.Fatalf("asset encrypted_data not base64: %v", err)
	}
	if string(decoded) != "secret creds for bank" {
		t.Fatalf("encrypted_data round-trip failed: got %q", decoded)
	}

	// update asset (new name, new payload, category_id -> null)
	newPayload := base64.StdEncoding.EncodeToString([]byte("rotated secret"))
	updBody := fmt.Sprintf(`{"name":"银行卡2","asset_type":"physical","category_id":null,"encrypted_data":%q,"expiry_date":null}`, newPayload)
	upd := doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/assets/%d", created.ID), updBody, token)
	if upd.Code != http.StatusOK {
		t.Fatalf("update asset: status=%d body=%s", upd.Code, upd.Body.String())
	}
	var updated assetResp
	if err := json.Unmarshal(upd.Body.Bytes(), &updated); err != nil {
		t.Fatalf("parse update asset: %v", err)
	}
	if updated.Name != "银行卡2" || updated.AssetType != "physical" || updated.CategoryID != nil || updated.ExpiryDate != nil {
		t.Fatalf("unexpected updated asset: %+v", updated)
	}
	if updated.EncryptedData != newPayload {
		t.Fatalf("updated encrypted_data mismatch: got %q", updated.EncryptedData)
	}

	// delete asset -> 204, then gone -> 404
	del := doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/assets/%d", created.ID), "", token)
	if del.Code != http.StatusNoContent {
		t.Fatalf("delete asset: status=%d want 204", del.Code)
	}
	if rr := doReq(t, ts, http.MethodGet, fmt.Sprintf("/api/v1/assets/%d", created.ID), "", token); rr.Code != http.StatusNotFound {
		t.Fatalf("get deleted asset: status=%d want 404", rr.Code)
	}

	// delete category -> 204
	delCat := doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/categories/%d", createdCat.ID), "", token)
	if delCat.Code != http.StatusNoContent {
		t.Fatalf("delete category: status=%d want 204 body=%s", delCat.Code, delCat.Body.String())
	}

	// asset validation: empty name / bad type / empty encrypted_data / bad base64 -> 400
	for _, body := range []string{
		`{"name":"","asset_type":"physical","encrypted_data":"AAAA"}`,
		`{"name":"x","asset_type":"digital","encrypted_data":"AAAA"}`,
		`{"name":"x","asset_type":"physical","encrypted_data":""}`,
		`{"name":"x","asset_type":"physical","encrypted_data":"not-valid-b64!!!"}`,
	} {
		if rr := doReq(t, ts, http.MethodPost, "/api/v1/assets", body, token); rr.Code != http.StatusBadRequest {
			t.Fatalf("validation case %s: status=%d want 400", body, rr.Code)
		}
	}
}

func TestResourceIsolation(t *testing.T) {
	ts, _ := newTestServer(t)
	tokenA := registerUser(t, ts, "alice")
	tokenB := registerUser(t, ts, "bob")

	// A: category + asset (name avoids the seeded presets)
	cat := doReq(t, ts, http.MethodPost, "/api/v1/categories", `{"name":"保险"}`, tokenA)
	var createdCat catResp
	if err := json.Unmarshal(cat.Body.Bytes(), &createdCat); err != nil {
		t.Fatalf("parse A category: %v", err)
	}
	payload := base64.StdEncoding.EncodeToString([]byte("alice's secret"))
	assetBody := fmt.Sprintf(`{"name":"银行卡","asset_type":"virtual","category_id":%d,"encrypted_data":%q}`, createdCat.ID, payload)
	asset := doReq(t, ts, http.MethodPost, "/api/v1/assets", assetBody, tokenA)
	var createdAsset assetResp
	if err := json.Unmarshal(asset.Body.Bytes(), &createdAsset); err != nil {
		t.Fatalf("parse A asset: %v", err)
	}

	path := fmt.Sprintf("/api/v1/assets/%d", createdAsset.ID)
	// B cannot GET/PUT/DELETE A's asset (PUT body must be valid for B, else
	// validation rejects first; ownership check is the one under test)
	putBody := `{"name":"x","asset_type":"physical","encrypted_data":"AAAA"}`
	for _, tc := range []struct {
		method string
		body   string
	}{
		{http.MethodGet, ""},
		{http.MethodPut, putBody},
		{http.MethodDelete, ""},
	} {
		rr := doReq(t, ts, tc.method, path, tc.body, tokenB)
		if rr.Code != http.StatusNotFound {
			t.Fatalf("B %s A's asset: status=%d want 404 body=%s", tc.method, rr.Code, rr.Body.String())
		}
	}
	// B cannot delete A's category
	rr := doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/categories/%d", createdCat.ID), "", tokenB)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("B delete A's category: status=%d want 404 body=%s", rr.Code, rr.Body.String())
	}
	// B's lists are empty
	rr = doReq(t, ts, http.MethodGet, "/api/v1/assets", "", tokenB)
	if rr.Code != http.StatusOK || strings.TrimSpace(rr.Body.String()) != "[]" {
		t.Fatalf("B asset list should be empty: status=%d body=%s", rr.Code, rr.Body.String())
	}
	// B's category list holds only B's seeded presets, never A's category
	rr = doReq(t, ts, http.MethodGet, "/api/v1/categories", "", tokenB)
	if rr.Code != http.StatusOK {
		t.Fatalf("B list categories: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var bCats []map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &bCats); err != nil {
		t.Fatalf("parse B category list: %v body=%s", err, rr.Body.String())
	}
	if len(bCats) != 10 {
		t.Fatalf("B category list len=%d want 10 presets body=%s", len(bCats), rr.Body.String())
	}
	for _, c := range bCats {
		if c["id"] == float64(createdCat.ID) {
			t.Fatalf("B category list leaks A's category: %s", rr.Body.String())
		}
	}
	// B referencing A's category -> 400 invalid category
	badCatBody := fmt.Sprintf(`{"name":"x","asset_type":"physical","category_id":%d,"encrypted_data":"AAAA"}`, createdCat.ID)
	if rr := doReq(t, ts, http.MethodPost, "/api/v1/assets", badCatBody, tokenB); rr.Code != http.StatusBadRequest || !json.Valid(rr.Body.Bytes()) {
		t.Fatalf("B asset with A's category: status=%d want 400 body=%s", rr.Code, rr.Body.String())
	}
	// A still owns the asset after B's attempts
	if rr := doReq(t, ts, http.MethodGet, path, "", tokenA); rr.Code != http.StatusOK {
		t.Fatalf("A get own asset after B attempts: status=%d", rr.Code)
	}
}

func TestResourcesUnauthorized(t *testing.T) {
	ts, _ := newTestServer(t)
	for _, tc := range []struct {
		method, path, body string
	}{
		{http.MethodGet, "/api/v1/categories", ""},
		{http.MethodPost, "/api/v1/categories", `{"name":"x"}`},
		{http.MethodDelete, "/api/v1/categories/1", ""},
		{http.MethodGet, "/api/v1/assets", ""},
		{http.MethodGet, "/api/v1/assets/1", ""},
		{http.MethodPost, "/api/v1/assets", `{}`},
		{http.MethodPut, "/api/v1/assets/1", `{}`},
		{http.MethodDelete, "/api/v1/assets/1", ""},
	} {
		rr := doReq(t, ts, tc.method, tc.path, tc.body, "")
		if rr.Code != http.StatusUnauthorized {
			t.Fatalf("%s %s without token: status=%d want 401", tc.method, tc.path, rr.Code)
		}
	}
}
