package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
)

// TestInheritorCategoryUnbind: 分组绑定解绑链路——列表把分组作为实体返回
// (一个分组一行,含经分组继承的资产数),携带 category_id 供解绑。
func TestInheritorCategoryUnbind(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")

	// 分类 + 分类下两个资产
	rr := doReq(t, ts, http.MethodPost, "/api/v1/categories", `{"name":"保险","asset_type":"physical"}`, token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create category: status=%d", rr.Code)
	}
	var cat catResp
	if err := json.Unmarshal(rr.Body.Bytes(), &cat); err != nil {
		t.Fatalf("parse category: %v", err)
	}
	payload := base64.StdEncoding.EncodeToString([]byte("secret"))
	for _, name := range []string{"保单A", "保单B"} {
		body := fmt.Sprintf(`{"name":%q,"asset_type":"physical","category_id":%d,"encrypted_data":%q}`,
			name, cat.ID, payload)
		if r := doReq(t, ts, http.MethodPost, "/api/v1/assets", body, token); r.Code != http.StatusCreated {
			t.Fatalf("create asset %s: status=%d", name, r.Code)
		}
	}

	// 继承人 + 分组绑定
	inID := createInheritor(t, ts, token, "bob", "bob@example.com", "abc12345")
	rr = doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/categories/%d/inheritors", cat.ID),
		fmt.Sprintf(`{"inheritor_id":%d}`, inID), token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("bind category: status=%d body=%s", rr.Code, rr.Body.String())
	}

	// 列表:分组作为一个实体返回(而非逐资产展开),asset_count=2,携带 category_id
	rr = doReq(t, ts, http.MethodGet, fmt.Sprintf("/api/v1/inheritors/%d/assets", inID), "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("list inheritor assets: status=%d", rr.Code)
	}
	var entries []inheritorAssetJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &entries); err != nil {
		t.Fatalf("parse list: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("want 1 group entry, got %d: %s", len(entries), rr.Body.String())
	}
	e := entries[0]
	if e.BindingType != "category" || e.CategoryID == nil || *e.CategoryID != cat.ID {
		t.Fatalf("category binding missing category_id: %+v", e)
	}
	if e.AssetCount != 2 || e.AssetID != nil {
		t.Fatalf("group entry: want asset_count=2 asset_id=null, got %+v", e)
	}

	// 用列表返回的 category_id + binding_id 解绑,应成功且列表清空
	rr = doReq(t, ts, http.MethodDelete,
		fmt.Sprintf("/api/v1/categories/%d/inheritors/%d", cat.ID, e.BindingID), "", token)
	if rr.Code != http.StatusNoContent && rr.Code != http.StatusOK {
		t.Fatalf("unbind: status=%d body=%s", rr.Code, rr.Body.String())
	}
	rr = doReq(t, ts, http.MethodGet, fmt.Sprintf("/api/v1/inheritors/%d/assets", inID), "", token)
	var after []inheritorAssetJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &after); err != nil {
		t.Fatalf("parse after: %v", err)
	}
	if len(after) != 0 {
		t.Fatalf("after unbind want empty, got %d: %s", len(after), rr.Body.String())
	}
}

// TestInheritorEmptyCategoryShows: 空分组绑定也作为实体出现在列表(可解绑)。
func TestInheritorEmptyCategoryShows(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "alice")
	rr := doReq(t, ts, http.MethodPost, "/api/v1/categories", `{"name":"空分组","asset_type":"physical"}`, token)
	var cat catResp
	json.Unmarshal(rr.Body.Bytes(), &cat)
	inID := createInheritor(t, ts, token, "bob", "bob@example.com", "abc12345")
	rr = doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/categories/%d/inheritors", cat.ID),
		fmt.Sprintf(`{"inheritor_id":%d}`, inID), token)
	if rr.Code != http.StatusCreated {
		t.Fatalf("bind empty category: status=%d", rr.Code)
	}
	rr = doReq(t, ts, http.MethodGet, fmt.Sprintf("/api/v1/inheritors/%d/assets", inID), "", token)
	var entries []inheritorAssetJSON
	json.Unmarshal(rr.Body.Bytes(), &entries)
	if len(entries) != 1 || entries[0].BindingType != "category" || entries[0].AssetCount != 0 {
		t.Fatalf("empty category should show as one entry with asset_count=0: %s", rr.Body.String())
	}
}
