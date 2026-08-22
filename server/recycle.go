package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
)

// ---------- 回收站(软删除资产/分组的恢复、永久删除、清空) ----------

type recycleItem struct {
	Kind     string `json:"kind"` // 'asset' | 'category'
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Detail   string `json:"detail"`
	Category *string `json:"category,omitempty"` // 资产原分组名(恢复提示用)
	DeletedAt string `json:"deleted_at"`
}

// handleListRecycleBin: GET /api/v1/recycle-bin -> 200 已软删除的资产与分组。
func handleListRecycleBin(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		items := []recycleItem{}
		// 资产(带原分组名,恢复时若分组不存在可提示)。
		rows, err := db.Query(`SELECT a.id, a.name, c.name, a.deleted_at
			FROM assets a LEFT JOIN categories c ON a.category_id = c.id
			WHERE a.user_id = ? AND a.deleted_at IS NOT NULL ORDER BY a.deleted_at DESC`, uid)
		if err != nil {
			log.Printf("list recycle assets: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		for rows.Next() {
			var it recycleItem
			var cat sql.NullString
			if err := rows.Scan(&it.ID, &it.Name, &cat, &it.DeletedAt); err != nil {
				rows.Close()
				log.Printf("scan recycle asset: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			it.Kind = "asset"
			if cat.Valid {
				it.Category = &cat.String
			}
			items = append(items, it)
		}
		rows.Close()
		// 分组。
		crows, err := db.Query(`SELECT id, name, remark, deleted_at
			FROM categories WHERE user_id = ? AND deleted_at IS NOT NULL ORDER BY deleted_at DESC`, uid)
		if err != nil {
			log.Printf("list recycle categories: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		for crows.Next() {
			var it recycleItem
			var remark sql.NullString
			if err := crows.Scan(&it.ID, &it.Name, &remark, &it.DeletedAt); err != nil {
				crows.Close()
				log.Printf("scan recycle category: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			it.Kind = "category"
			if remark.Valid {
				it.Detail = remark.String
			}
			items = append(items, it)
		}
		crows.Close()
		writeJSON(w, http.StatusOK, items)
	}
}

// handleRestoreRecycleItem: POST /api/v1/recycle-bin/{kind}/{id}/restore ->
// 200 {"ok":true}. 恢复软删除项:
// - 资产:deleted_at 置空;原分组若已被删除(软删/硬删),移到"未分类"。
// - 分组:deleted_at 置空。
func handleRestoreRecycleItem(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		kind := r.PathValue("kind")
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		var name string
		if kind == "asset" {
			if err := db.QueryRow(`SELECT name FROM assets WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`, id, uid).Scan(&name); err != nil {
				if errors.Is(err, sql.ErrNoRows) {
					writeError(w, http.StatusNotFound, "回收站项目不存在")
					return
				}
				log.Printf("query recycle asset: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			// 恢复资产:先置空 deleted_at;若原分组已不存在(被删除),category_id 置 NULL。
			res, err := db.Exec(`UPDATE assets SET deleted_at = NULL,
				category_id = CASE WHEN category_id IS NOT NULL AND EXISTS
					(SELECT 1 FROM categories c WHERE c.id = assets.category_id AND c.user_id = assets.user_id)
					THEN category_id ELSE NULL END
				WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`, id, uid)
			if err != nil {
				log.Printf("restore asset: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if n, _ := res.RowsAffected(); n == 0 {
				writeError(w, http.StatusNotFound, "回收站项目不存在")
				return
			}
		} else if kind == "category" {
			if err := db.QueryRow(`SELECT name FROM categories WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`, id, uid).Scan(&name); err != nil {
				if errors.Is(err, sql.ErrNoRows) {
					writeError(w, http.StatusNotFound, "回收站项目不存在")
					return
				}
				log.Printf("query recycle category: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			res, err := db.Exec(`UPDATE categories SET deleted_at = NULL WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`, id, uid)
			if err != nil {
				log.Printf("restore category: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if n, _ := res.RowsAffected(); n == 0 {
				writeError(w, http.StatusNotFound, "回收站项目不存在")
				return
			}
		} else {
			writeError(w, http.StatusBadRequest, "无效的项目类型")
			return
		}
		kindLabel := "资产"
		if kind == "category" {
			kindLabel = "分组"
		}
		logAudit(db, uid, fmt.Sprintf("恢复回收站中的%s「%s」", kindLabel, name), map[string]any{"kind": kind, "id": id})
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	}
}

// handlePurgeRecycleItem: DELETE /api/v1/recycle-bin/{kind}/{id} -> 204 永久删除。
func handlePurgeRecycleItem(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		kind := r.PathValue("kind")
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "无效的 ID")
			return
		}
		uid := userID(r)
		var name string
		if kind == "asset" {
			if err := db.QueryRow(`SELECT name FROM assets WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`, id, uid).Scan(&name); err != nil {
				if errors.Is(err, sql.ErrNoRows) {
					writeError(w, http.StatusNotFound, "回收站项目不存在")
					return
				}
				log.Printf("query purge asset: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
		} else if kind == "category" {
			if err := db.QueryRow(`SELECT name FROM categories WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`, id, uid).Scan(&name); err != nil {
				if errors.Is(err, sql.ErrNoRows) {
					writeError(w, http.StatusNotFound, "回收站项目不存在")
					return
				}
				log.Printf("query purge category: %v", err)
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
		} else {
			writeError(w, http.StatusBadRequest, "无效的项目类型")
			return
		}
		var res sql.Result
		if kind == "asset" {
			res, err = db.Exec(`DELETE FROM assets WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`, id, uid)
		} else {
			res, err = db.Exec(`DELETE FROM categories WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`, id, uid)
		}
		if err != nil {
			log.Printf("purge recycle item: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "回收站项目不存在")
			return
		}
		kindLabel := "资产"
		if kind == "category" {
			kindLabel = "分组"
		}
		logAudit(db, uid, fmt.Sprintf("永久删除回收站中的%s「%s」", kindLabel, name), map[string]any{"kind": kind, "id": id})
		w.WriteHeader(http.StatusNoContent)
	}
}

// handleEmptyRecycleBin: DELETE /api/v1/recycle-bin -> 204 永久清空回收站。
func handleEmptyRecycleBin(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var nAssets, nCats int
		db.QueryRow(`SELECT COUNT(*) FROM assets WHERE user_id = ? AND deleted_at IS NOT NULL`, uid).Scan(&nAssets)
		db.QueryRow(`SELECT COUNT(*) FROM categories WHERE user_id = ? AND deleted_at IS NOT NULL`, uid).Scan(&nCats)
		if _, err := db.Exec(`DELETE FROM assets WHERE user_id = ? AND deleted_at IS NOT NULL`, uid); err != nil {
			log.Printf("empty recycle assets: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if _, err := db.Exec(`DELETE FROM categories WHERE user_id = ? AND deleted_at IS NOT NULL`, uid); err != nil {
			log.Printf("empty recycle categories: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		logAudit(db, uid, fmt.Sprintf("清空回收站(共 %d 项)", nAssets+nCats), nil)
		w.WriteHeader(http.StatusNoContent)
	}
}

// handleBatchDeleteAssets: POST /api/v1/assets/batch-delete {ids:[]} -> 200 批量软删除。
func handleBatchDeleteAssets(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			IDs []int64 `json:"ids"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "请求数据格式错误")
			return
		}
		if len(req.IDs) == 0 || len(req.IDs) > 500 {
			writeError(w, http.StatusBadRequest, "无效的 ID 列表")
			return
		}
		placeholders := strings.Repeat("?,", len(req.IDs)-1) + "?"
		args := make([]any, 0, len(req.IDs)+1)
		for _, id := range req.IDs {
			args = append(args, id)
		}
		args = append(args, userID(r))
		res, err := db.Exec(`UPDATE assets SET deleted_at = datetime('now')
			WHERE id IN (`+placeholders+`) AND user_id = ? AND deleted_at IS NULL`, args...)
		if err != nil {
			log.Printf("batch delete assets: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		n, _ := res.RowsAffected()
		logAudit(db, userID(r), fmt.Sprintf("批量删除 %d 个资产", n), map[string]any{"ids": req.IDs})
		writeJSON(w, http.StatusOK, map[string]int64{"deleted": n})
	}
}
