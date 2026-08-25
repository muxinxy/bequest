package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

// TestLadderValidate:validateLadderDays 单元测试。
func TestLadderValidate(t *testing.T) {
	cases := []struct {
		days []int
		ok   bool // true = 合法
	}{
		{[]int{30, 90}, true},
		{[]int{30, 90, 120}, false},      // 3 个
		{[]int{30, 30}, false},           // 非严格递增
		{[]int{30, 0}, false},            // 含 0
		{[]int{30, 5000}, false},         // 超 3650
	}
	for _, c := range cases {
		got := validateLadderDays(c.days)
		if c.ok && got != "" {
			t.Fatalf("validateLadderDays(%v) = %q, want valid", c.days, got)
		}
		if !c.ok && got == "" {
			t.Fatalf("validateLadderDays(%v) = valid, want error", c.days)
		}
	}
}

// TestLadderCRUD:创建 → 201;列表含它;PUT 修改 → 200;DELETE → deleted=1。
func TestLadderCRUD(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")

	rr := doReq(t, ts, http.MethodPost, "/api/v1/trigger-ladders",
		`{"name":"阶梯A","days":[10,20]}`, token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create ladder: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var created ladderJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &created); err != nil {
		t.Fatalf("parse created ladder: %v", err)
	}
	if created.Name != "阶梯A" || created.IsGlobal != 0 || len(created.Days) != 2 {
		t.Fatalf("unexpected created ladder: %+v", created)
	}

	// 列表包含它
	rr = doReq(t, ts, http.MethodGet, "/api/v1/trigger-ladders", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("list ladders: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var list []ladderJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
		t.Fatalf("parse list: %v", err)
	}
	found := false
	for _, l := range list {
		if l.ID == created.ID {
			found = true
		}
	}
	if !found {
		t.Fatalf("list missing created ladder: %s", rr.Body.String())
	}

	// 修改
	rr = doReq(t, ts, http.MethodPut, fmt.Sprintf("/api/v1/trigger-ladders/%d", created.ID),
		`{"name":"阶梯B","days":[5,10]}`, token)
	if rr.Code != http.StatusOK {
		t.Fatalf("update ladder: status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), `"name":"阶梯B"`) {
		t.Fatalf("update not applied: %s", rr.Body.String())
	}

	// 删除
	rr = doReq(t, ts, http.MethodDelete, "/api/v1/trigger-ladders",
		fmt.Sprintf(`{"ids":[%d]}`, created.ID), token)
	if rr.Code != http.StatusOK {
		t.Fatalf("delete ladder: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var del struct {
		Deleted int `json:"deleted"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &del); err != nil {
		t.Fatalf("parse delete: %v", err)
	}
	if del.Deleted != 1 {
		t.Fatalf("deleted = %d, want 1", del.Deleted)
	}
}

// TestLadderDeleteRevertsBindings:删除阶梯后,引用它的分组继承绑定 ladder_id 回退 NULL。
func TestLadderDeleteRevertsBindings(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	cat := makeCat(t, ts, token, "保险")
	inID := createInheritor(t, ts, token, "bob", "bob@example.com", "abc12345")

	// 建阶梯A
	rr := doReq(t, ts, http.MethodPost, "/api/v1/trigger-ladders",
		`{"name":"阶梯A","days":[10,20]}`, token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create ladder: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var ladder ladderJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &ladder); err != nil {
		t.Fatalf("parse ladder: %v", err)
	}

	// 绑定到分组继承
	rr = doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/categories/%d/inheritors", cat.ID),
		fmt.Sprintf(`{"inheritor_id":%d,"ladder_id":%d}`, inID, ladder.ID), token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("bind: status=%d body=%s", rr.Code, rr.Body.String())
	}

	// 确认绑定带 ladder_id
	var boundLadder sql.NullInt64
	if err := db.QueryRow(`SELECT ladder_id FROM category_inheritors WHERE category_id = ? AND inheritor_id = ?`,
		cat.ID, inID).Scan(&boundLadder); err != nil {
		t.Fatalf("query binding: %v", err)
	}
	if !boundLadder.Valid || boundLadder.Int64 != ladder.ID {
		t.Fatalf("binding ladder_id = %v, want %d", boundLadder, ladder.ID)
	}

	// 删除阶梯A -> 绑定回退 NULL
	rr = doReq(t, ts, http.MethodDelete, "/api/v1/trigger-ladders",
		fmt.Sprintf(`{"ids":[%d]}`, ladder.ID), token)
	if rr.Code != http.StatusOK {
		t.Fatalf("delete ladder: status=%d body=%s", rr.Code, rr.Body.String())
	}
	if err := db.QueryRow(`SELECT ladder_id FROM category_inheritors WHERE category_id = ? AND inheritor_id = ?`,
		cat.ID, inID).Scan(&boundLadder); err != nil {
		t.Fatalf("query binding after delete: %v", err)
	}
	if boundLadder.Valid {
		t.Fatalf("binding ladder_id = %d, want NULL after ladder delete", boundLadder.Int64)
	}
}

// TestLadderGlobalNotDeletable:删除全局阶梯(is_global=1)→ skipped=1,deleted=0。
func TestLadderGlobalNotDeletable(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")

	// 列表触发 ensureGlobalLadder 补建全局阶梯
	rr := doReq(t, ts, http.MethodGet, "/api/v1/trigger-ladders", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("list ladders: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var list []ladderJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
		t.Fatalf("parse list: %v", err)
	}
	var globalID int64
	for _, l := range list {
		if l.IsGlobal == 1 {
			globalID = l.ID
		}
	}
	if globalID == 0 {
		t.Fatalf("no global ladder seeded: %s", rr.Body.String())
	}

	rr = doReq(t, ts, http.MethodDelete, "/api/v1/trigger-ladders",
		fmt.Sprintf(`{"ids":[%d]}`, globalID), token)
	if rr.Code != http.StatusOK {
		t.Fatalf("delete global: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var del struct {
		Deleted int `json:"deleted"`
		Skipped int `json:"skipped"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &del); err != nil {
		t.Fatalf("parse delete: %v", err)
	}
	if del.Skipped != 1 || del.Deleted != 0 {
		t.Fatalf("global delete: deleted=%d skipped=%d, want 0/1", del.Deleted, del.Skipped)
	}
}

// TestLadderBindings:自定义阶梯绑定资产/分组后,GET bindings 返回资产 status
// 与分组列表;全局阶梯返回 ladder_id IS NULL 的绑定。
func TestLadderBindings(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")

	// 建 2 资产 + 1 分组
	cat := makeCat(t, ts, token, "保险")
	assetA := createAssetInCat(t, ts, token, 0, "房产")
	assetB := createAssetInCat(t, ts, token, cat.ID, "保单")
	inID := createInheritor(t, ts, token, "bob", "bob@example.com", "abc12345")

	// 建自定义阶梯
	rr := doReq(t, ts, http.MethodPost, "/api/v1/trigger-ladders",
		`{"name":"阶梯A","days":[10,20]}`, token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create ladder: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var ladder ladderJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &ladder); err != nil {
		t.Fatalf("parse ladder: %v", err)
	}

	// 绑定资产A + 分组到自定义阶梯
	if rr := doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/assets/%d/inheritors", assetA),
		fmt.Sprintf(`{"inheritor_id":%d,"ladder_id":%d}`, inID, ladder.ID), token); rr.Code != http.StatusCreated {
		t.Fatalf("bind asset: status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr := doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/categories/%d/inheritors", cat.ID),
		fmt.Sprintf(`{"inheritor_id":%d,"ladder_id":%d}`, inID, ladder.ID), token); rr.Code != http.StatusCreated {
		t.Fatalf("bind category: status=%d body=%s", rr.Code, rr.Body.String())
	}
	// 资产B 绑定到全局阶梯(ladder_id null)
	if rr := doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/assets/%d/inheritors", assetB),
		fmt.Sprintf(`{"inheritor_id":%d,"ladder_id":null}`, inID), token); rr.Code != http.StatusCreated {
		t.Fatalf("bind assetB global: status=%d body=%s", rr.Code, rr.Body.String())
	}

	// 自定义阶梯 bindings:assets[0].status='active',categories 长度 1
	rr = doReq(t, ts, http.MethodGet, fmt.Sprintf("/api/v1/trigger-ladders/%d/bindings", ladder.ID), "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("list custom bindings: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var custom struct {
		Assets     []ladderBindingAsset     `json:"assets"`
		Categories []ladderBindingCategory `json:"categories"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &custom); err != nil {
		t.Fatalf("parse custom bindings: %v", err)
	}
	if len(custom.Assets) != 1 || custom.Assets[0].Status != "active" {
		t.Fatalf("custom assets: %+v, want 1 with status active", custom.Assets)
	}
	if len(custom.Categories) != 1 {
		t.Fatalf("custom categories len=%d, want 1", len(custom.Categories))
	}

	// 全局阶梯 bindings:返回 ladder_id IS NULL 的绑定(资产B 未绑自定义 -> 全局)
	rr = doReq(t, ts, http.MethodGet, "/api/v1/trigger-ladders", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("list ladders: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var list []ladderJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
		t.Fatalf("parse list: %v", err)
	}
	var globalID int64
	for _, l := range list {
		if l.IsGlobal == 1 {
			globalID = l.ID
		}
	}
	if globalID == 0 {
		t.Fatalf("no global ladder: %s", rr.Body.String())
	}
	rr = doReq(t, ts, http.MethodGet, fmt.Sprintf("/api/v1/trigger-ladders/%d/bindings", globalID), "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("list global bindings: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var global struct {
		Assets     []ladderBindingAsset     `json:"assets"`
		Categories []ladderBindingCategory `json:"categories"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &global); err != nil {
		t.Fatalf("parse global bindings: %v", err)
	}
	// 资产B 未绑自定义阶梯 -> 全局绑定含它;资产A 已绑自定义 -> 不在全局
	foundB := false
	for _, a := range global.Assets {
		if a.AssetID == assetB {
			foundB = true
		}
		if a.AssetID == assetA {
			t.Fatalf("global bindings should not contain custom-bound assetA: %+v", global.Assets)
		}
	}
	if !foundB {
		t.Fatalf("global bindings missing assetB: %+v", global.Assets)
	}
}