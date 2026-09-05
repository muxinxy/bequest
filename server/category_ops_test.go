package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// makeCat creates a category and returns its JSON.
func makeCat(t *testing.T, ts *httptest.Server, token, name string) categoryJSON {
	t.Helper()
	rr := doReq(t, ts, http.MethodPost, "/api/v1/categories", fmt.Sprintf(`{"name":%q}`, name), token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create category %s: status=%d body=%s", name, rr.Code, rr.Body.String())
	}
	var c categoryJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &c); err != nil {
		t.Fatalf("parse category: %v", err)
	}
	return c
}

// createAssetInCat creates an asset under a category (catID=0 -> 未分类)。
func createAssetInCat(t *testing.T, ts *httptest.Server, token string, catID int64, name string) int64 {
	t.Helper()
	payload := base64.StdEncoding.EncodeToString([]byte("secret"))
	catJSON := "null"
	if catID != 0 {
		catJSON = fmt.Sprint(catID)
	}
	rr := doReq(t, ts, http.MethodPost, "/api/v1/assets",
		fmt.Sprintf(`{"name":%q,"asset_type":"physical","category_id":%s,"encrypted_data":%q}`, name, catJSON, payload), token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create asset %s: status=%d body=%s", name, rr.Code, rr.Body.String())
	}
	var a assetResp
	if err := json.Unmarshal(rr.Body.Bytes(), &a); err != nil {
		t.Fatalf("parse asset: %v", err)
	}
	return a.ID
}

// getCategories fetches the category list (含预设)。
func getCategories(t *testing.T, ts *httptest.Server, token string) []categoryJSON {
	t.Helper()
	rr := doReq(t, ts, http.MethodGet, "/api/v1/categories", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("list categories: status=%d", rr.Code)
	}
	var cats []categoryJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &cats); err != nil {
		t.Fatalf("parse categories: %v", err)
	}
	return cats
}

// TestCategorySort: 自定义排序 + 列表按 sort_order 返回。
func TestCategorySort(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")
	c1 := makeCat(t, ts, token, "甲")
	c2 := makeCat(t, ts, token, "乙")
	c3 := makeCat(t, ts, token, "丙")

	// 排序:丙→甲→乙
	rr := doReq(t, ts, http.MethodPut, "/api/v1/categories/order",
		fmt.Sprintf(`{"ids":[%d,%d,%d]}`, c3.ID, c1.ID, c2.ID), token)
	if rr.Code != http.StatusOK {
		t.Fatalf("reorder: status=%d body=%s", rr.Code, rr.Body.String())
	}
	cats := getCategories(t, ts, token)
	idx := map[int64]int{}
	for i, c := range cats {
		idx[c.ID] = i
	}
	if idx[c3.ID] >= idx[c1.ID] || idx[c1.ID] >= idx[c2.ID] {
		t.Fatalf("order wrong: c3<c1<c2 expected, got %+v", cats)
	}
	// 越权:其他用户的 id → 404
	tokenB := registerUser(t, ts, "bob")
	rr = doReq(t, ts, http.MethodPut, "/api/v1/categories/order", `{"ids":[999999]}`, tokenB)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("reorder foreign: want 404, got %d", rr.Code)
	}
}

// TestCategoryDeleteMoveTo: 删除分组带 move_to 迁移资产,asset_count 正确。
func TestCategoryDeleteMoveTo(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")
	src := makeCat(t, ts, token, "源")
	dst := makeCat(t, ts, token, "目标")
	createAssetInCat(t, ts, token, src.ID, "保单A")
	createAssetInCat(t, ts, token, src.ID, "保单B")

	// asset_count 反映组内资产数
	cats := getCategories(t, ts, token)
	for _, c := range cats {
		if c.ID == src.ID && c.AssetCount != 2 {
			t.Fatalf("src asset_count = %d, want 2", c.AssetCount)
		}
	}

	// 删除并迁移
	rr := doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/categories/%d?move_to=%d", src.ID, dst.ID), "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("delete with move: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var moved struct {
		Moved int64 `json:"moved"`
	}
	json.Unmarshal(rr.Body.Bytes(), &moved)
	if moved.Moved != 2 {
		t.Fatalf("moved = %d, want 2", moved.Moved)
	}
	// 源分组已删,目标分组 asset_count = 2
	cats = getCategories(t, ts, token)
	for _, c := range cats {
		if c.ID == src.ID {
			t.Fatal("source category still exists")
		}
		if c.ID == dst.ID && c.AssetCount != 2 {
			t.Fatalf("dst asset_count = %d, want 2", c.AssetCount)
		}
	}
	// move_to 指向自己的分组 → 400
	rr = doReq(t, ts, http.MethodDelete, fmt.Sprintf("/api/v1/categories/%d?move_to=%d", dst.ID, dst.ID), "", token)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("move to self: want 400, got %d", rr.Code)
	}
}

// TestBatchMoveAssets: 批量移动资产到分组/未分类。
func TestBatchMoveAssets(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")
	cat := makeCat(t, ts, token, "目标")
	a1 := createAssetInCat(t, ts, token, 0, "资产1") // 未分类
	a2 := createAssetInCat(t, ts, token, 0, "资产2")
	rr := doReq(t, ts, http.MethodPost, "/api/v1/assets/move",
		fmt.Sprintf(`{"ids":[%d,%d],"category_id":%d}`, a1, a2, cat.ID), token)
	if rr.Code != http.StatusOK {
		t.Fatalf("batch move: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var moved struct {
		Moved int64 `json:"moved"`
	}
	json.Unmarshal(rr.Body.Bytes(), &moved)
	if moved.Moved != 2 {
		t.Fatalf("moved = %d, want 2", moved.Moved)
	}
	cats := getCategories(t, ts, token)
	for _, c := range cats {
		if c.ID == cat.ID && c.AssetCount != 2 {
			t.Fatalf("after batch move asset_count = %d, want 2", c.AssetCount)
		}
	}
	// 移到未分类(category_id null)
	rr = doReq(t, ts, http.MethodPost, "/api/v1/assets/move",
		fmt.Sprintf(`{"ids":[%d],"category_id":null}`, a1), token)
	if rr.Code != http.StatusOK {
		t.Fatalf("move to uncategorized: status=%d", rr.Code)
	}
}

// TestCategoryInheritorAssetsPreview: 分组绑定继承预览(排除资产级绑定)。
func TestCategoryInheritorAssetsPreview(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")
	cat := makeCat(t, ts, token, "保险")
	inCat := createAssetInCat(t, ts, token, cat.ID, "保单A")
	createAssetInCat(t, ts, token, cat.ID, "保单B")

	inID := createInheritor(t, ts, token, "bob", "bob@example.com", "abc12345")
	rr := doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/categories/%d/inheritors", cat.ID),
		fmt.Sprintf(`{"inheritor_id":%d}`, inID), token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("bind: status=%d", rr.Code)
	}
	var bind struct {
		ID int64 `json:"id"`
	}
	json.Unmarshal(rr.Body.Bytes(), &bind)

	// 预览:2 个资产
	rr = doReq(t, ts, http.MethodGet, fmt.Sprintf("/api/v1/categories/%d/inheritors/%d/assets", cat.ID, bind.ID), "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("preview: status=%d body=%s", rr.Code, rr.Body.String())
	}
	var pre struct {
		Assets []struct {
			ID int64 `json:"id"`
		} `json:"assets"`
	}
	json.Unmarshal(rr.Body.Bytes(), &pre)
	if len(pre.Assets) != 2 {
		t.Fatalf("preview count = %d, want 2: %s", len(pre.Assets), rr.Body.String())
	}

	// 保单A 资产级绑定后:预览只剩 1 个
	rr = doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/assets/%d/inheritors", inCat),
		fmt.Sprintf(`{"inheritor_id":%d}`, inID), token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("asset bind: status=%d", rr.Code)
	}
	rr = doReq(t, ts, http.MethodGet, fmt.Sprintf("/api/v1/categories/%d/inheritors/%d/assets", cat.ID, bind.ID), "", token)
	json.Unmarshal(rr.Body.Bytes(), &pre)
	if len(pre.Assets) != 1 {
		t.Fatalf("after asset-level bind preview count = %d, want 1", len(pre.Assets))
	}
}
