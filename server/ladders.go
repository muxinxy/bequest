package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
)

// ---------- 触发阶梯 ----------

type ladderJSON struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	IsGlobal  int    `json:"is_global"`
	Days      []int  `json:"days"`
	CreatedAt string `json:"created_at"`
}

type ladderRequest struct {
	Name string `json:"name"`
	Days []int  `json:"days"`
}

// defaultLadderDays 返回默认触发阶梯的 JSON 数组字符串(用于补建全局阶梯)。
// 免费/会员统一用全局默认配置 defaultLadderConfig。
func defaultLadderDays(tier string) string {
	b, _ := json.Marshal(defaultLadderConfig)
	return string(b)
}

// ensureGlobalLadder 为该用户补建全局阶梯(存量用户兼容),返回其 id。
func ensureGlobalLadder(db *sql.DB, uid int64) int64 {
	var id int64
	err := db.QueryRow(`SELECT id FROM trigger_ladders WHERE user_id = ? AND is_global = 1`, uid).Scan(&id)
	if err == nil {
		return id
	}
	var tier string
	if err := db.QueryRow(`SELECT tier FROM users WHERE id = ?`, uid).Scan(&tier); err != nil {
		return 0
	}
	res, err := db.Exec(`INSERT INTO trigger_ladders (user_id, name, is_global, days) VALUES (?, '全局', 1, ?)`,
		uid, defaultLadderDays(tier))
	if err != nil {
		log.Printf("ensure global ladder: %v", err)
		return 0
	}
	id, _ = res.LastInsertId()
	return id
}

// ladderOwnedBy 报告阶梯是否存在且属于 uid。
func ladderOwnedBy(db *sql.DB, ladderID, uid int64) bool {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM trigger_ladders WHERE id = ? AND user_id = ?`,
		ladderID, uid).Scan(&n); err == nil {
		return n > 0
	}
	return false
}

// validateLadderDays:必须恰好 2 个严格递增正整数
// (语义:一级 IM+邮件,二级 一级+短信),每个 1-3650 天(约 10 年)。
func validateLadderDays(days []int) string {
	const msg = "触发阶梯需要 2 个依次递增的正整数(一级:IM+邮件, 二级:一级+短信),每个 1-3650 天"
	if len(days) != 2 {
		return msg
	}
	for i, d := range days {
		if d <= 0 || d > 3650 || (i > 0 && d <= days[i-1]) {
			return msg
		}
	}
	return ""
}

// scanLadder 从一行扫描出阶梯 JSON(含 days JSON 解析)。
func scanLadder(row *sql.Row) (*ladderJSON, error) {
	var l ladderJSON
	var days string
	if err := row.Scan(&l.ID, &l.Name, &l.IsGlobal, &days, &l.CreatedAt); err != nil {
		return nil, err
	}
	if err := json.Unmarshal([]byte(days), &l.Days); err != nil {
		l.Days = []int{}
	}
	return &l, nil
}

// handleListTriggerLadders: GET /api/v1/trigger-ladders -> 200 [{id,name,is_global,days,created_at}]
// 无全局阶梯时自动补建(存量用户兼容)。
func handleListTriggerLadders(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		ensureGlobalLadder(db, uid)
		rows, err := db.Query(`SELECT id, name, is_global, days, created_at
			FROM trigger_ladders WHERE user_id = ? ORDER BY is_global DESC, id`, uid)
		if err != nil {
			log.Printf("list ladders: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		list := []ladderJSON{}
		for rows.Next() {
			var l ladderJSON
			var days string
			if err := rows.Scan(&l.ID, &l.Name, &l.IsGlobal, &days, &l.CreatedAt); err != nil {
				log.Printf("scan ladder: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if err := json.Unmarshal([]byte(days), &l.Days); err != nil {
				l.Days = []int{}
			}
			list = append(list, l)
		}
		writeJSON(w, http.StatusOK, list)
	}
}

// handleCreateTriggerLadder: POST /api/v1/trigger-ladders {name,days} -> 201
func handleCreateTriggerLadder(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req ladderRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if strings.TrimSpace(req.Name) == "" {
			writeError(w, http.StatusBadRequest, "名称必填")
			return
		}
		if msg := validateLadderDays(req.Days); msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		days, _ := json.Marshal(req.Days)
		res, err := db.Exec(`INSERT INTO trigger_ladders (user_id, name, is_global, days) VALUES (?, ?, 0, ?)`,
			uid, strings.TrimSpace(req.Name), string(days))
		if err != nil {
			log.Printf("insert ladder: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		id, _ := res.LastInsertId()
		logAudit(db, uid, fmt.Sprintf("新增触发阶梯「%s」", strings.TrimSpace(req.Name)), map[string]any{"id": id, "days": req.Days})
		l, err := scanLadder(db.QueryRow(`SELECT id, name, is_global, days, created_at FROM trigger_ladders WHERE id = ?`, id))
		if err != nil {
			log.Printf("fetch ladder: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusCreated, l)
	}
}

// handleUpdateTriggerLadder: PUT /api/v1/trigger-ladders/{id} {name,days} -> 200
// 全局阶梯也可改 days/name。
func handleUpdateTriggerLadder(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		var req ladderRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if strings.TrimSpace(req.Name) == "" {
			writeError(w, http.StatusBadRequest, "名称必填")
			return
		}
		if msg := validateLadderDays(req.Days); msg != "" {
			writeError(w, http.StatusBadRequest, msg)
			return
		}
		days, _ := json.Marshal(req.Days)
		res, err := db.Exec(`UPDATE trigger_ladders SET name = ?, days = ? WHERE id = ? AND user_id = ?`,
			strings.TrimSpace(req.Name), string(days), id, uid)
		if err != nil {
			log.Printf("update ladder: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "触发阶梯不存在")
			return
		}
		logAudit(db, uid, fmt.Sprintf("修改触发阶梯「%s」", strings.TrimSpace(req.Name)), map[string]any{"id": id, "days": req.Days})
		l, err := scanLadder(db.QueryRow(`SELECT id, name, is_global, days, created_at FROM trigger_ladders WHERE id = ?`, id))
		if err != nil {
			log.Printf("fetch ladder: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusOK, l)
	}
}

// handleDeleteTriggerLadders: DELETE /api/v1/trigger-ladders {ids:[int]} -> 200 {"deleted":n,"skipped":m}
// 全局阶梯不可删(跳过);删除后引用它的继承绑定自动回退全局(NULL)。
func handleDeleteTriggerLadders(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req struct {
			IDs []int64 `json:"ids"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if len(req.IDs) == 0 {
			writeError(w, http.StatusBadRequest, "请提供 ID 列表")
			return
		}
		deleted, skipped := 0, 0
		boundAssets, boundCategories := 0, 0
		var delIDs []int64
		for _, id := range req.IDs {
			var isGlobal int
			var owner int64
			err := db.QueryRow(`SELECT is_global, user_id FROM trigger_ladders WHERE id = ?`, id).Scan(&isGlobal, &owner)
			if err != nil || owner != uid {
				continue // 不存在或非本人:忽略
			}
			if isGlobal == 1 {
				skipped++
				continue
			}
			// 删除前统计受影响绑定数(供前端提示"将解绑 N 个资产、M 个分组")。
			var na, nc int
			db.QueryRow(`SELECT COUNT(*) FROM asset_inheritors WHERE ladder_id = ?`, id).Scan(&na)
			db.QueryRow(`SELECT COUNT(*) FROM category_inheritors WHERE ladder_id = ?`, id).Scan(&nc)
			if _, err := db.Exec(`DELETE FROM trigger_ladders WHERE id = ? AND user_id = ?`, id, uid); err != nil {
				log.Printf("delete ladder: %v", err)
				continue
			}
			deleted++
			boundAssets += na
			boundCategories += nc
			delIDs = append(delIDs, id)
		}
		if len(delIDs) > 0 {
			placeholders := strings.TrimSuffix(strings.Repeat("?,", len(delIDs)), ",")
			args := make([]any, len(delIDs))
			for i, id := range delIDs {
				args[i] = id
			}
			if _, err := db.Exec(`UPDATE asset_inheritors SET ladder_id = NULL WHERE ladder_id IN (`+placeholders+`)`, args...); err != nil {
				log.Printf("unlink asset bindings: %v", err)
			}
			if _, err := db.Exec(`UPDATE category_inheritors SET ladder_id = NULL WHERE ladder_id IN (`+placeholders+`)`, args...); err != nil {
				log.Printf("unlink category bindings: %v", err)
			}
		}
		logAudit(db, uid, fmt.Sprintf("删除触发阶梯(共 %d 个)", deleted), map[string]any{"deleted": deleted, "skipped": skipped})
		writeJSON(w, http.StatusOK, map[string]int{"deleted": deleted, "skipped": skipped, "bound_assets": boundAssets, "bound_categories": boundCategories})
	}
}

// ---------- 阶梯绑定管理 ----------

// ladderBindingAsset/Category 的 binding_id 即 asset_inheritors/category_inheritors.id,
// 前端按"绑定行"(资产/分组 + 继承人)粒度选中与解绑。
type ladderBindingAsset struct {
	BindingID     int64  `json:"binding_id"`
	AssetID       int64  `json:"asset_id"`
	Name          string `json:"name"`
	Status        string `json:"status"`
	InheritorID   int64  `json:"inheritor_id"`
	InheritorName string `json:"inheritor_name"`
}

type ladderBindingCategory struct {
	BindingID     int64  `json:"binding_id"`
	CategoryID    int64  `json:"category_id"`
	Name          string `json:"name"`
	InheritorID   int64  `json:"inheritor_id"`
	InheritorName string `json:"inheritor_name"`
}

// handleListLadderBindings: GET /api/v1/trigger-ladders/{id}/bindings -> 200
// 返回该阶梯绑定的资产/分组及各自继承人。
// 全局阶梯(is_global=1)返回所有 ladder_id IS NULL 的绑定(默认=全局);
// 自定义阶梯返回 ladder_id=该 id 的绑定。
func handleListLadderBindings(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		var isGlobal int
		if err := db.QueryRow(`SELECT is_global FROM trigger_ladders WHERE id = ? AND user_id = ?`, id, uid).Scan(&isGlobal); err != nil {
			writeError(w, http.StatusNotFound, "触发阶梯不存在")
			return
		}
		// 全局阶梯:ladder_id IS NULL;自定义:ladder_id = id。
		ladderCond := "ai.ladder_id IS NULL"
		catCond := "ci.ladder_id IS NULL"
		if isGlobal == 0 {
			ladderCond = "ai.ladder_id = ?"
			catCond = "ci.ladder_id = ?"
		}
		assets := []ladderBindingAsset{}
		assetArgs := []any{uid}
		if isGlobal == 0 {
			assetArgs = append(assetArgs, id)
		}
		arows, err := db.Query(`SELECT ai.id, ai.asset_id, a.name, a.status, ai.inheritor_id, i.name
			FROM asset_inheritors ai
			JOIN assets a ON a.id = ai.asset_id
			JOIN inheritors i ON i.id = ai.inheritor_id
			WHERE a.user_id = ? AND `+ladderCond+` ORDER BY ai.asset_id, ai.priority, ai.id`, assetArgs...)
		if err != nil {
			log.Printf("list ladder asset bindings: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		for arows.Next() {
			var b ladderBindingAsset
			if err := arows.Scan(&b.BindingID, &b.AssetID, &b.Name, &b.Status, &b.InheritorID, &b.InheritorName); err != nil {
				log.Printf("scan ladder asset binding: %v", err)
				arows.Close()
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			assets = append(assets, b)
		}
		arows.Close()

		categories := []ladderBindingCategory{}
		catArgs := []any{uid}
		if isGlobal == 0 {
			catArgs = append(catArgs, id)
		}
		crows, err := db.Query(`SELECT ci.id, ci.category_id, c.name, ci.inheritor_id, i.name
			FROM category_inheritors ci
			JOIN categories c ON c.id = ci.category_id
			JOIN inheritors i ON i.id = ci.inheritor_id
			WHERE c.user_id = ? AND `+catCond+` ORDER BY ci.category_id, ci.priority, ci.id`, catArgs...)
		if err != nil {
			log.Printf("list ladder category bindings: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		for crows.Next() {
			var b ladderBindingCategory
			if err := crows.Scan(&b.BindingID, &b.CategoryID, &b.Name, &b.InheritorID, &b.InheritorName); err != nil {
				log.Printf("scan ladder category binding: %v", err)
				crows.Close()
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			categories = append(categories, b)
		}
		crows.Close()

		writeJSON(w, http.StatusOK, map[string]any{"assets": assets, "categories": categories})
	}
}

// handleUnbindLadder: POST /api/v1/trigger-ladders/unbind
// body {"ladder_id":5,"asset_bindings":[binding_id...],"category_bindings":[binding_id...]} -> 200
// 解绑 = 把对应 asset_inheritors/category_inheritors 的 ladder_id 置 NULL(回全局)。
// binding_id 即绑定行 id(asset_inheritors/category_inheritors.id),按"资产/分组+继承人"粒度解绑。
// 全局阶梯(is_global=1)的绑定即默认,解绑无意义,返回 400。
func handleUnbindLadder(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var req struct {
			LadderID         int64   `json:"ladder_id"`
			AssetBindings    []int64 `json:"asset_bindings"`
			CategoryBindings []int64 `json:"category_bindings"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if !ladderOwnedBy(db, req.LadderID, uid) {
			writeError(w, http.StatusNotFound, "触发阶梯不存在")
			return
		}
		var isGlobal int
		if err := db.QueryRow(`SELECT is_global FROM trigger_ladders WHERE id = ?`, req.LadderID).Scan(&isGlobal); err != nil || isGlobal == 1 {
			writeError(w, http.StatusBadRequest, "全局阶梯无需解绑")
			return
		}
		unboundAssets, unboundCategories := 0, 0
		if len(req.AssetBindings) > 0 {
			// 仅解绑属于该用户资产、且当前归属该阶梯的绑定行。
			args := []any{req.LadderID}
			args = append(args, toAny(req.AssetBindings)...)
			args = append(args, uid)
			res, err := db.Exec(`UPDATE asset_inheritors SET ladder_id = NULL
				WHERE ladder_id = ? AND id IN (`+placeholders(len(req.AssetBindings))+`)
				AND asset_id IN (SELECT id FROM assets WHERE user_id = ?)`, args...)
			if err != nil {
				log.Printf("unbind assets: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			n, _ := res.RowsAffected()
			unboundAssets = int(n)
		}
		if len(req.CategoryBindings) > 0 {
			args := []any{req.LadderID}
			args = append(args, toAny(req.CategoryBindings)...)
			args = append(args, uid)
			res, err := db.Exec(`UPDATE category_inheritors SET ladder_id = NULL
				WHERE ladder_id = ? AND id IN (`+placeholders(len(req.CategoryBindings))+`)
				AND category_id IN (SELECT id FROM categories WHERE user_id = ?)`, args...)
			if err != nil {
				log.Printf("unbind categories: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			n, _ := res.RowsAffected()
			unboundCategories = int(n)
		}
		logAudit(db, uid, "解绑触发阶梯绑定", map[string]any{"ladder_id": req.LadderID, "assets": unboundAssets, "categories": unboundCategories})
		writeJSON(w, http.StatusOK, map[string]int{"unbound_assets": unboundAssets, "unbound_categories": unboundCategories})
	}
}

// placeholders 生成 n 个 "?" 占位符(逗号分隔)。
func placeholders(n int) string {
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

// toAny 把 []int64 转为 []any。
func toAny(ids []int64) []any {
	out := make([]any, len(ids))
	for i, id := range ids {
		out[i] = id
	}
	return out
}
