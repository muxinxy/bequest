package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"
)

// TestDefaultInheritor: 注册用户 + 建 2 继承人(priority 1=张三, 2=李四)
// -> PUT default-inheritor {李四} -> 触发继承 -> 用户级事件(inheritance_events
// WHERE asset_id IS NULL)的 inheritor_id = 李四;预览的 user_level_inheritors 含李四。
// 校验:PUT 不存在的 inheritor_id -> 400;他人继承人也 400。
func TestDefaultInheritor(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")

	zhang := createInheritor(t, ts, token, "张三", "zhang@example.com", "abc12345")
	li := createInheritor(t, ts, token, "李四", "li@example.com", "abc12345")
	// 张三 priority 1(第一顺位),李四 priority 2。
	if _, err := db.Exec(`UPDATE inheritors SET priority = 1 WHERE id = ?`, zhang); err != nil {
		t.Fatalf("set zhang priority: %v", err)
	}
	if _, err := db.Exec(`UPDATE inheritors SET priority = 2 WHERE id = ?`, li); err != nil {
		t.Fatalf("set li priority: %v", err)
	}

	// 校验:PUT 不存在的 inheritor_id -> 400。
	if rr := doReq(t, ts, http.MethodPut, "/api/v1/inheritance/default-inheritor", `{"inheritor_id":99999}`, token); rr.Code != http.StatusBadRequest {
		t.Fatalf("PUT nonexistent inheritor: %d want 400", rr.Code)
	}
	// 校验:他人继承人也 400。
	tokenB := registerUser(t, ts, "bob")
	other := createInheritor(t, ts, tokenB, "王五", "wang@example.com", "abc12345")
	if rr := doReq(t, ts, http.MethodPut, "/api/v1/inheritance/default-inheritor", fmt.Sprintf(`{"inheritor_id":%d}`, other), token); rr.Code != http.StatusBadRequest {
		t.Fatalf("PUT other's inheritor: %d want 400", rr.Code)
	}

	// PUT default-inheritor {李四} -> 200 返回 default_inheritor_id。
	rr := doReq(t, ts, http.MethodPut, "/api/v1/inheritance/default-inheritor", fmt.Sprintf(`{"inheritor_id":%d}`, li), token)
	if rr.Code != http.StatusOK {
		t.Fatalf("PUT default-inheritor: %d body=%s", rr.Code, rr.Body.String())
	}
	var putResp struct {
		DefaultInheritorID *int64 `json:"default_inheritor_id"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &putResp); err != nil {
		t.Fatalf("parse PUT resp: %v", err)
	}
	if putResp.DefaultInheritorID == nil || *putResp.DefaultInheritorID != li {
		t.Fatalf("PUT resp default_inheritor_id=%v want %d", putResp.DefaultInheritorID, li)
	}

	// GET default-inheritor -> 200 返回李四。
	rr = doReq(t, ts, http.MethodGet, "/api/v1/inheritance/default-inheritor", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("GET default-inheritor: %d body=%s", rr.Code, rr.Body.String())
	}
	var getResp struct {
		InheritorID   *int64 `json:"inheritor_id"`
		InheritorName string `json:"inheritor_name"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &getResp); err != nil {
		t.Fatalf("parse GET resp: %v", err)
	}
	if getResp.InheritorID == nil || *getResp.InheritorID != li || getResp.InheritorName != "李四" {
		t.Fatalf("GET resp=%+v want id=%d name=李四", getResp, li)
	}

	// 触发继承:建一个未绑定资产(走用户级全量事件),last_login -130 天 + scan。
	if rr := createAsset(t, ts, token, "钱包"); rr.Code != http.StatusCreated {
		t.Fatalf("create asset: %d body=%s", rr.Code, rr.Body.String())
	}
	setLastLogin(t, db, uid, "-130 days")
	scan(db, time.Now().UTC())

	// 用户级事件(inheritance_events WHERE asset_id IS NULL)的 inheritor_id = 李四。
	var evInID int64
	if err := db.QueryRow(`SELECT inheritor_id FROM inheritance_events WHERE user_id = ? AND asset_id IS NULL`, uid).Scan(&evInID); err != nil {
		t.Fatalf("query user-level event: %v", err)
	}
	if evInID != li {
		t.Fatalf("user-level event inheritor_id=%d want %d (李四)", evInID, li)
	}

	// 预览的 user_level_inheritors 含李四。
	rr = doReq(t, ts, http.MethodGet, "/api/v1/inheritance/preview", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("preview: %d body=%s", rr.Code, rr.Body.String())
	}
	var preview struct {
		UserLevelInheritors []string `json:"user_level_inheritors"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &preview); err != nil {
		t.Fatalf("parse preview: %v", err)
	}
	if len(preview.UserLevelInheritors) != 1 || preview.UserLevelInheritors[0] != "李四" {
		t.Fatalf("user_level_inheritors=%v want [李四]", preview.UserLevelInheritors)
	}

	// 清空默认继承人(null) -> 回退第一顺位(张三)。
	if rr := doReq(t, ts, http.MethodPut, "/api/v1/inheritance/default-inheritor", `{"inheritor_id":null}`, token); rr.Code != http.StatusOK {
		t.Fatalf("PUT null default-inheritor: %d body=%s", rr.Code, rr.Body.String())
	}
	rr = doReq(t, ts, http.MethodGet, "/api/v1/inheritance/default-inheritor", "", token)
	if err := json.Unmarshal(rr.Body.Bytes(), &getResp); err != nil {
		t.Fatalf("parse GET resp 2: %v", err)
	}
	if getResp.InheritorID != nil {
		t.Fatalf("GET after null: inheritor_id=%v want nil", getResp.InheritorID)
	}
}
