package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
)

// TestListAssetsPaging: 分页 + 分组筛选,同时兼容无参旧行为(数组)。
func TestListAssetsPaging(t *testing.T) {
	ts, _ := newTestServer(t)
	token := registerUser(t, ts, "page-user")

	// 造 1 个分组 + 3 个资产(2 个同分组,1 个未分组)
	gid := makeCat(t, ts, token, "分页分组").ID
	createAssetInCat(t, ts, token, gid, "a1")
	createAssetInCat(t, ts, token, gid, "a2")
	createAssetInCat(t, ts, token, 0, "a3")

	// 无参 -> 200 且是数组(长度 3)
	rr := doReq(t, ts, http.MethodGet, "/api/v1/assets", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("no-param status=%d body=%s", rr.Code, rr.Body.String())
	}
	var arr []assetListJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &arr); err != nil {
		t.Fatalf("no-param should be array: %v body=%s", err, rr.Body.String())
	}
	if len(arr) != 3 {
		t.Fatalf("no-param array len=%d, want 3", len(arr))
	}

	// 分组筛选 + 分页 -> {"items":长度1, "total":2}
	rr = doReq(t, ts, http.MethodGet,
		fmt.Sprintf("/api/v1/assets?category_id=%d&limit=1&offset=0", gid), "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("paged status=%d body=%s", rr.Code, rr.Body.String())
	}
	var page struct {
		Items []assetListJSON `json:"items"`
		Total int             `json:"total"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &page); err != nil {
		t.Fatalf("paged should be object: %v body=%s", err, rr.Body.String())
	}
	if len(page.Items) != 1 || page.Total != 2 {
		t.Fatalf("paged items=%d total=%d, want 1/2", len(page.Items), page.Total)
	}

	// category_id=0 -> 未分组,total=1
	rr = doReq(t, ts, http.MethodGet, "/api/v1/assets?category_id=0", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("ungrouped status=%d body=%s", rr.Code, rr.Body.String())
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &page); err != nil {
		t.Fatalf("ungrouped parse: %v body=%s", err, rr.Body.String())
	}
	if page.Total != 1 || len(page.Items) != 1 {
		t.Fatalf("ungrouped total=%d items=%d, want 1/1", page.Total, len(page.Items))
	}

	// limit=200 正常
	rr = doReq(t, ts, http.MethodGet, "/api/v1/assets?limit=200", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("limit=200 status=%d body=%s", rr.Code, rr.Body.String())
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &page); err != nil {
		t.Fatalf("limit=200 parse: %v body=%s", err, rr.Body.String())
	}
	if page.Total != 3 || len(page.Items) != 3 {
		t.Fatalf("limit=200 total=%d items=%d, want 3/3", page.Total, len(page.Items))
	}
}
