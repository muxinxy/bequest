package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

type presetCat struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	AssetType string `json:"asset_type"`
	IsPreset  int    `json:"is_preset"`
	CreatedAt string `json:"created_at"`
}

func listCategories(t *testing.T, ts *httptest.Server, token string) []presetCat {
	t.Helper()
	rr := doReq(t, ts, http.MethodGet, "/api/v1/categories", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("list categories: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var cats []presetCat
	if err := json.Unmarshal(rr.Body.Bytes(), &cats); err != nil {
		t.Fatalf("parse category list: %v body=%s", err, rr.Body.String())
	}
	return cats
}

func TestRegisterSeedsPresetCategories(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "preset-user")

	cats := listCategories(t, ts, token)
	if len(cats) != 10 {
		t.Fatalf("seeded category count = %d, want 10: %+v", len(cats), cats)
	}
	var physical, virtual int
	for _, c := range cats {
		if c.IsPreset != 1 {
			t.Fatalf("seeded category is_preset = %d, want 1: %+v", c.IsPreset, c)
		}
		if c.AssetType != "physical" && c.AssetType != "virtual" {
			t.Fatalf("seeded category asset_type = %q, want physical/virtual: %+v", c.AssetType, c)
		}
		if c.AssetType == "physical" {
			physical++
		} else {
			virtual++
		}
	}
	if physical != 5 || virtual != 5 {
		t.Fatalf("seeded split physical=%d virtual=%d, want 5/5", physical, virtual)
	}
}

func TestCreateCategoryAssetType(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "type-user")

	// explicit virtual -> 201 with asset_type virtual, is_preset 0
	rr := doReq(t, ts, http.MethodPost, "/api/v1/categories", `{"name":"信托","asset_type":"virtual"}`, token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create virtual category: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var c presetCat
	if err := json.Unmarshal(rr.Body.Bytes(), &c); err != nil {
		t.Fatalf("parse created category: %v", err)
	}
	if c.AssetType != "virtual" || c.IsPreset != 0 {
		t.Fatalf("unexpected created category: %+v", c)
	}

	// asset_type omitted -> defaults to physical
	rr = doReq(t, ts, http.MethodPost, "/api/v1/categories", `{"name":"保险柜"}`, token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create default category: status=%d body=%s", rr.Code, rr.Body.String())
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &c); err != nil {
		t.Fatalf("parse default category: %v", err)
	}
	if c.AssetType != "physical" {
		t.Fatalf("default asset_type = %q, want physical", c.AssetType)
	}

	// invalid asset_type -> 400 (empty/omitted defaults to physical, so not tested here)
	if rr := doReq(t, ts, http.MethodPost, "/api/v1/categories", `{"name":"x","asset_type":"digital"}`, token); rr.Code != http.StatusBadRequest {
		t.Fatalf("invalid asset_type: status=%d want 400 body=%s", rr.Code, rr.Body.String())
	}
}

func TestUpdateCategory(t *testing.T) {
	ts, _ := newTestServer(t)
	tokenA := registerUser(t, ts, "put-user-a")
	tokenB := registerUser(t, ts, "put-user-b")

	cats := listCategories(t, ts, tokenA)
	var preset *presetCat
	for i := range cats {
		if cats[i].Name == "车辆" {
			preset = &cats[i]
			break
		}
	}
	if preset == nil {
		t.Fatalf("preset 车辆 not found: %+v", cats)
	}

	// rename + retarget a preset -> 200, GET reflects it
	rr := doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/categories/%d", preset.ID),
		`{"name":"交通工具","asset_type":"virtual"}`, tokenA)
	if rr.Code != http.StatusOK {
		t.Fatalf("put rename preset: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var updated presetCat
	if err := json.Unmarshal(rr.Body.Bytes(), &updated); err != nil {
		t.Fatalf("parse updated category: %v", err)
	}
	if updated.Name != "交通工具" || updated.AssetType != "virtual" || updated.IsPreset != 1 {
		t.Fatalf("unexpected updated category: %+v", updated)
	}
	got := listCategories(t, ts, tokenA)
	found := false
	for _, c := range got {
		if c.ID == preset.ID {
			found = true
			if c.Name != "交通工具" || c.AssetType != "virtual" {
				t.Fatalf("GET after PUT mismatch: %+v", c)
			}
		}
	}
	if !found {
		t.Fatalf("updated preset missing from list: %+v", got)
	}

	// rename to an existing name -> 409
	rr = doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/categories/%d", preset.ID),
		`{"name":"银行账户","asset_type":"virtual"}`, tokenA)
	if rr.Code != http.StatusConflict {
		t.Fatalf("put duplicate name: status=%d want 409 body=%s", rr.Code, rr.Body.String())
	}

	// retarget-only PUT (same name, new type) -> 200, no false duplicate
	rr = doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/categories/%d", preset.ID),
		`{"name":"交通工具","asset_type":"physical"}`, tokenA)
	if rr.Code != http.StatusOK {
		t.Fatalf("put retarget only: status=%d body=%s", rr.Code, rr.Body.String())
	}

	// validation -> 400
	for _, body := range []string{
		`{"name":"   ","asset_type":"physical"}`,
		`{"name":"ok","asset_type":"digital"}`,
	} {
		rr := doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/categories/%d", preset.ID), body, tokenA)
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("put validation %s: status=%d want 400", body, rr.Code)
		}
	}

	// other user's category -> 404
	rr = doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/categories/%d", preset.ID),
		`{"name":"偷","asset_type":"physical"}`, tokenB)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("B put A's category: status=%d want 404 body=%s", rr.Code, rr.Body.String())
	}

	// missing id -> 404
	rr = doReq(t, ts, http.MethodPut, "/api/v1/categories/999999",
		`{"name":"nope","asset_type":"physical"}`, tokenA)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("put missing id: status=%d want 404 body=%s", rr.Code, rr.Body.String())
	}
}

func TestDeletePresetCategory(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "del-user")

	cats := listCategories(t, ts, token)
	var target *presetCat
	for i := range cats {
		if cats[i].Name == "贵金属" {
			target = &cats[i]
			break
		}
	}
	if target == nil {
		t.Fatalf("preset 贵金属 not found: %+v", cats)
	}

	rr := doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/categories/%d", target.ID), "", token)
	if rr.Code != http.StatusNoContent {
		t.Fatalf("delete preset: status=%d want 204 body=%s", rr.Code, rr.Body.String())
	}
	got := listCategories(t, ts, token)
	if len(got) != 9 {
		t.Fatalf("categories after deleting preset = %d, want 9", len(got))
	}
	for _, c := range got {
		if c.ID == target.ID {
			t.Fatalf("deleted preset still present: %+v", c)
		}
	}
}
