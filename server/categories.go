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

// userID returns the authenticated user's id from the request context
// (populated by requireAuth).
func userID(r *http.Request) int64 {
	return r.Context().Value(ctxUserIDKey).(int64)
}

// parseID reads the {id} path wildcard as an int64.
func parseID(r *http.Request) (int64, error) {
	return strconv.ParseInt(r.PathValue("id"), 10, 64)
}

// ---------- categories ----------

type categoryJSON struct {
	ID         int64  `json:"id"`
	Name       string `json:"name"`
	AssetType  string `json:"asset_type"`
	IsPreset   int    `json:"is_preset"`
	CreatedAt  string `json:"created_at"`
	SortOrder  int    `json:"sort_order"`
	AssetCount       int      `json:"asset_count"`
	Remark           string   `json:"remark"`
	InheritorNames   []string `json:"inheritor_names,omitempty"` // 绑定的继承人名字
}

// validAssetType reports whether s is a supported category type.
func validAssetType(s string) bool {
	return s == "physical" || s == "virtual"
}

// scanCategory fills a categoryJSON from the canonical column order:
// id, name, asset_type, is_preset, created_at, sort_order, asset_count, remark.
func scanCategory(scanner interface{ Scan(...any) error }) (*categoryJSON, error) {
	var c categoryJSON
	var remark sql.NullString
	if err := scanner.Scan(&c.ID, &c.Name, &c.AssetType, &c.IsPreset, &c.CreatedAt, &c.SortOrder, &c.AssetCount, &remark); err != nil {
		return nil, err
	}
	if remark.Valid {
		c.Remark = remark.String
	}
	return &c, nil
}

// handleListCategories: GET /api/v1/categories -> 200 [] (按 sort_order 排序,排除回收站)
// 每个分组带 asset_count 与绑定的继承人名字(inheritor_names)。可选 ?q= 按名称模糊过滤。
// 可选 ?limit=(默认 100,最大 200)&offset=(默认 0)分页:带参数时返回
// {"items":[...],"total":n};不带参数保持数组(兼容旧调用)。
func handleListCategories(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		where := "c.user_id = ? AND c.deleted_at IS NULL"
		args := []any{userID(r)}
		if search := r.URL.Query().Get("q"); search != "" {
			where += " AND c.name LIKE ?"
			args = append(args, "%"+search+"%")
		}
		// 分页:仅当显式传 limit/offset 时启用。
		paged := false
		limit, offset := 100, 0
		if v := r.URL.Query().Get("limit"); v != "" {
			paged = true
			limit, _ = strconv.Atoi(v)
			if limit <= 0 {
				limit = 100
			}
			if limit > 200 {
				limit = 200
			}
		}
		if v := r.URL.Query().Get("offset"); v != "" {
			paged = true
			offset, _ = strconv.Atoi(v)
			if offset < 0 {
				offset = 0
			}
		}
		sqlStr := `SELECT c.id, c.name, c.asset_type, c.is_preset, c.created_at, c.sort_order,
				(SELECT COUNT(*) FROM assets a WHERE a.category_id = c.id AND a.deleted_at IS NULL) AS asset_count,
				c.remark,
				(SELECT GROUP_CONCAT(i.name, '、') FROM category_inheritors ci
					JOIN inheritors i ON i.id = ci.inheritor_id
					WHERE ci.category_id = c.id) AS inheritor_names
			FROM categories c WHERE ` + where + ` ORDER BY c.sort_order, c.id`
		if paged {
			sqlStr += fmt.Sprintf(" LIMIT %d OFFSET %d", limit, offset)
		}
		rows, err := db.Query(sqlStr, args...)
		if err != nil {
			log.Printf("list categories: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer rows.Close()
		cats := []categoryJSON{}
		for rows.Next() {
			var c categoryJSON
			var remark, names sql.NullString
			if err := rows.Scan(&c.ID, &c.Name, &c.AssetType, &c.IsPreset, &c.CreatedAt, &c.SortOrder,
				&c.AssetCount, &remark, &names); err != nil {
				log.Printf("scan category: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if remark.Valid {
				c.Remark = remark.String
			}
			if names.Valid && names.String != "" {
				c.InheritorNames = strings.Split(names.String, "、")
			}
			cats = append(cats, c)
		}
		if paged {
			var total int
			if err := db.QueryRow(`SELECT COUNT(*) FROM categories c WHERE `+where, args...).Scan(&total); err != nil {
				log.Printf("count categories: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"items": cats, "total": total})
			return
		}
		writeJSON(w, http.StatusOK, cats)
	}
}

// handleCreateCategory: POST /api/v1/categories -> 201; 400 empty name / bad
// asset_type; 409 duplicate
func handleCreateCategory(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Name      string `json:"name"`
			AssetType string `json:"asset_type"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		name := strings.TrimSpace(req.Name)
		if name == "" {
			writeError(w, http.StatusBadRequest, "名称必填")
			return
		}
		assetType := req.AssetType
		if assetType == "" {
			assetType = "physical"
		}
		if !validAssetType(assetType) {
			writeError(w, http.StatusBadRequest, "资产类型必须为 physical 或 virtual")
			return
		}
		res, err := db.Exec(`INSERT INTO categories (user_id, name, asset_type, is_preset) VALUES (?, ?, ?, 0)`, userID(r), name, assetType)
		if err != nil {
			if isUniqueViolation(err) {
				writeError(w, http.StatusConflict, "分组已存在")
				return
			}
			log.Printf("insert category: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		id, _ := res.LastInsertId()
		// 新分组排最后(sort_order 用 id 即单调递增)。
		db.Exec(`UPDATE categories SET sort_order = ? WHERE id = ?`, id, id)
		c, err := scanCategory(db.QueryRow(`SELECT id, name, asset_type, is_preset, created_at, sort_order,
			(SELECT COUNT(*) FROM assets a WHERE a.category_id = categories.id AND a.deleted_at IS NULL),
			remark FROM categories WHERE id = ?`, id))
		if err != nil {
			log.Printf("fetch created category: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		logAudit(db, userID(r), fmt.Sprintf("新建分组「%s」", c.Name), map[string]any{"id": id})
		writeJSON(w, http.StatusCreated, c)
	}
}

// handleUpdateCategory: PUT /api/v1/categories/{id} -> 200; 400 empty name /
// bad asset_type; 409 duplicate (excluding self); 404 not owned. Renaming or
// retargeting works on preset rows too.
func handleUpdateCategory(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		var req struct {
			Name      string `json:"name"`
			AssetType string `json:"asset_type"`
			Remark    string `json:"remark"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		nameRaw := req.Name
		name := strings.TrimSpace(nameRaw)
		assetType := req.AssetType
		if assetType == "" {
			assetType = "physical"
		}
		if !validAssetType(assetType) {
			writeError(w, http.StatusBadRequest, "资产类型必须为 physical 或 virtual")
			return
		}
		// name 可省略(仅更新备注/asset_type 时):JSON 缺省为 ""。
		// 一旦显式传入 name,则必须是非空名称(纯空格 → 400),并检查重复。
		if nameRaw != "" {
			if name == "" {
				writeError(w, http.StatusBadRequest, "名称必填")
				return
			}
			var dup int
			if err := db.QueryRow(`SELECT COUNT(*) FROM categories
				WHERE user_id = ? AND name = ? AND id != ? AND deleted_at IS NULL`,
				userID(r), name, id).Scan(&dup); err != nil {
				log.Printf("check category name: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if dup > 0 {
				writeError(w, http.StatusConflict, "分组已存在")
				return
			}
		}
		remark := req.Remark
		var remarkArg any
		if remark != "" {
			remarkArg = remark
		}
		var res sql.Result
		if name != "" {
			res, err = db.Exec(`UPDATE categories SET name = ?, asset_type = ?, remark = ? WHERE id = ? AND user_id = ?`,
				name, assetType, remarkArg, id, userID(r))
		} else {
			res, err = db.Exec(`UPDATE categories SET asset_type = ?, remark = ? WHERE id = ? AND user_id = ?`,
				assetType, remarkArg, id, userID(r))
		}
		if err != nil {
			if isUniqueViolation(err) {
				writeError(w, http.StatusConflict, "分组已存在")
				return
			}
			log.Printf("update category: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "分组不存在")
			return
		}
		c, err := scanCategory(db.QueryRow(`SELECT id, name, asset_type, is_preset, created_at, sort_order,
			(SELECT COUNT(*) FROM assets a WHERE a.category_id = categories.id AND a.deleted_at IS NULL),
			remark FROM categories WHERE id = ?`, id))
		if err != nil {
			log.Printf("fetch updated category: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		logAudit(db, userID(r), fmt.Sprintf("修改分组「%s」", c.Name), map[string]any{"id": id})
		writeJSON(w, http.StatusOK, c)
	}
}

// handleReorderCategories: PUT /api/v1/categories/order {ids:[...]} ->
// 200 {"ok":true}. 按给定顺序写入 sort_order(0,1,2,...)。
func handleReorderCategories(db *sql.DB) http.HandlerFunc {
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
		tx, err := db.Begin()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		defer tx.Rollback()
		for i, id := range req.IDs {
			res, err := tx.Exec(`UPDATE categories SET sort_order = ? WHERE id = ? AND user_id = ?`, i, id, uid)
			if err != nil {
				log.Printf("reorder categories: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if n, _ := res.RowsAffected(); n == 0 {
				writeError(w, http.StatusNotFound, "分组不存在")
				return
			}
		}
		if err := tx.Commit(); err != nil {
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		logApp(db, uid, "调整分组排序", map[string]any{"ids": req.IDs})
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	}
}

// handleDeleteCategory: DELETE /api/v1/categories/{id}?move_to={target} -> 204
// (或 200 {"moved":n} 当带 move_to)。move_to 先把该分组资产移入目标分组再删,
// 防止误删后资产散落"未分类"。分组继承人绑定由 ON DELETE CASCADE 清理。
// 软删除(deleted_at = now)进回收站,恢复见 handleRestoreItem。
func handleDeleteCategory(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		// 确认分组存在且属于当前用户,并取名称用于审计日志。
		var name string
		if err := db.QueryRow(`SELECT name FROM categories WHERE id = ? AND user_id = ? AND deleted_at IS NULL`, id, uid).Scan(&name); err != nil {
			writeError(w, http.StatusNotFound, "分组不存在")
			return
		}
		moved := int64(0)
		if moveTo := strings.TrimSpace(r.URL.Query().Get("move_to")); moveTo != "" {
			target, err := strconv.ParseInt(moveTo, 10, 64)
			if err != nil || target == id {
				writeError(w, http.StatusBadRequest, "无效的 move_to 参数")
				return
			}
			var m int
			if err := db.QueryRow(`SELECT COUNT(*) FROM categories WHERE id = ? AND user_id = ?`, target, uid).Scan(&m); err != nil || m == 0 {
				writeError(w, http.StatusNotFound, "目标分组不存在")
				return
			}
			res, err := db.Exec(`UPDATE assets SET category_id = ? WHERE category_id = ? AND user_id = ?`, target, id, uid)
			if err != nil {
				log.Printf("move assets before delete: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			moved, _ = res.RowsAffected()
		}
		if _, err := db.Exec(`UPDATE categories SET deleted_at = datetime('now') WHERE id = ? AND user_id = ?`, id, uid); err != nil {
			log.Printf("soft delete category: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		logAudit(db, uid, fmt.Sprintf("删除分组「%s」", name), map[string]any{"id": id, "moved_assets": moved})
		if moved > 0 {
			writeJSON(w, http.StatusOK, map[string]int64{"moved": moved})
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}
