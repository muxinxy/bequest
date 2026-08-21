package main

import (
	"database/sql"
	"encoding/json"
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
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		for rows.Next() {
			var it recycleItem
			var cat sql.NullString
			if err := rows.Scan(&it.ID, &it.Name, &cat, &it.DeletedAt); err != nil {
				rows.Close()
				log.Printf("scan recycle asset: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
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
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		for crows.Next() {
			var it recycleItem
			var remark sql.NullString
			if err := crows.Scan(&it.ID, &it.Name, &remark, &it.DeletedAt); err != nil {
				crows.Close()
				log.Printf("scan recycle category: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
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
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		uid := userID(r)
		if kind == "asset" {
			// 恢复资产:先置空 deleted_at;若原分组已不存在(被删除),category_id 置 NULL。
			res, err := db.Exec(`UPDATE assets SET deleted_at = NULL,
				category_id = CASE WHEN category_id IS NOT NULL AND EXISTS
					(SELECT 1 FROM categories c WHERE c.id = assets.category_id AND c.user_id = assets.user_id)
					THEN category_id ELSE NULL END
				WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`, id, uid)
			if err != nil {
				log.Printf("restore asset: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			if n, _ := res.RowsAffected(); n == 0 {
				writeError(w, http.StatusNotFound, "item not found")
				return
			}
		} else if kind == "category" {
			res, err := db.Exec(`UPDATE categories SET deleted_at = NULL WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`, id, uid)
			if err != nil {
				log.Printf("restore category: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
				return
			}
			if n, _ := res.RowsAffected(); n == 0 {
				writeError(w, http.StatusNotFound, "item not found")
				return
			}
		} else {
			writeError(w, http.StatusBadRequest, "invalid kind")
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	}
}

// handlePurgeRecycleItem: DELETE /api/v1/recycle-bin/{kind}/{id} -> 204 永久删除。
func handlePurgeRecycleItem(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		kind := r.PathValue("kind")
		id, err := parseID(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		uid := userID(r)
		var res sql.Result
		if kind == "asset" {
			res, err = db.Exec(`DELETE FROM assets WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`, id, uid)
		} else if kind == "category" {
			res, err = db.Exec(`DELETE FROM categories WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`, id, uid)
		} else {
			writeError(w, http.StatusBadRequest, "invalid kind")
			return
		}
		if err != nil {
			log.Printf("purge recycle item: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "item not found")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

// handleEmptyRecycleBin: DELETE /api/v1/recycle-bin -> 204 永久清空回收站。
func handleEmptyRecycleBin(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		if _, err := db.Exec(`DELETE FROM assets WHERE user_id = ? AND deleted_at IS NOT NULL`, uid); err != nil {
			log.Printf("empty recycle assets: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if _, err := db.Exec(`DELETE FROM categories WHERE user_id = ? AND deleted_at IS NOT NULL`, uid); err != nil {
			log.Printf("empty recycle categories: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
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
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		if len(req.IDs) == 0 || len(req.IDs) > 500 {
			writeError(w, http.StatusBadRequest, "invalid ids")
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
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		n, _ := res.RowsAffected()
		writeJSON(w, http.StatusOK, map[string]int64{"deleted": n})
	}
}
