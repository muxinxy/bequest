package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
)

// TestTemplateDefault: 默认模板机制。
// 会员建 type='expiry' 模板A(首个自动默认)→ 建模板B(非默认)→
// list 断言 A.is_default=1 B=0 → POST B/default → A=0 B=1 →
// renderTemplate(type=expiry) 返回 B 的内容。
func TestTemplateDefault(t *testing.T) {
	ts, db := newTestServer(t)
	token := registerUser(t, ts, "alice")
	uid := getUID(t, db, "alice")
	if _, err := db.Exec(`UPDATE users SET tier = 'member' WHERE id = ?`, uid); err != nil {
		t.Fatalf("set tier member: %v", err)
	}

	create := func(name, title, body string) templateJSON {
		t.Helper()
		rr := doReq(t, ts, http.MethodPost, "/api/v1/reminder-templates",
			fmt.Sprintf(`{"name":%q,"type":"expiry","title_template":%q,"body_template":%q}`, name, title, body), token)
		if rr.Code != http.StatusCreated {
			t.Fatalf("create %s: %d body=%s", name, rr.Code, rr.Body.String())
		}
		var tpl templateJSON
		if err := json.Unmarshal(rr.Body.Bytes(), &tpl); err != nil {
			t.Fatalf("parse created %s: %v", name, err)
		}
		return tpl
	}

	// 首个自动默认,第二个非默认。
	a := create("模板A", "A标题 {name}", "A正文 {date}")
	if a.IsDefault != 1 {
		t.Fatalf("first template is_default = %d, want 1", a.IsDefault)
	}
	b := create("模板B", "B标题 {name}", "B正文 {date}")
	if b.IsDefault != 0 {
		t.Fatalf("second template is_default = %d, want 0", b.IsDefault)
	}

	// list 断言。
	rr := doReq(t, ts, http.MethodGet, "/api/v1/reminder-templates", "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("list templates: %d body=%s", rr.Code, rr.Body.String())
	}
	var list []templateJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
		t.Fatalf("parse list: %v", err)
	}
	for _, tpl := range list {
		switch tpl.ID {
		case a.ID:
			if tpl.IsDefault != 1 {
				t.Fatalf("list A is_default = %d, want 1", tpl.IsDefault)
			}
		case b.ID:
			if tpl.IsDefault != 0 {
				t.Fatalf("list B is_default = %d, want 0", tpl.IsDefault)
			}
		}
	}

	// 设 B 为默认。
	rr = doReq(t, ts, http.MethodPost, fmt.Sprintf("/api/v1/reminder-templates/%d/default", b.ID), "", token)
	if rr.Code != http.StatusOK {
		t.Fatalf("set default: %d body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		ID        int64 `json:"id"`
		IsDefault bool  `json:"is_default"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse set default: %v", err)
	}
	if resp.ID != b.ID || !resp.IsDefault {
		t.Fatalf("set default resp = %+v", resp)
	}

	// 渲染应返回 B 的内容。
	title, body := renderTemplate(db, uid, "expiry", map[string]string{"name": "王", "date": "2026-01-01"})
	if title != "B标题 王" || body != "B正文 2026-01-01" {
		t.Fatalf("renderTemplate = %q / %q, want B content", title, body)
	}

	// 免费用户不能建自定义模板(现有 400),默认机制只对会员。
	freeToken := registerUser(t, ts, "bob")
	if rr := doReq(t, ts, http.MethodPost, "/api/v1/reminder-templates",
		`{"name":"x","type":"expiry","title_template":"t","body_template":"b"}`, freeToken); rr.Code != http.StatusBadRequest {
		t.Fatalf("free user create template: %d want 400", rr.Code)
	}
}