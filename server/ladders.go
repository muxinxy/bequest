package main

import (
	"database/sql"
	"encoding/json"
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

// defaultLadderDays 返回 tier 默认升级天数的 JSON 数组字符串(用于补建全局阶梯)。
func defaultLadderDays(tier string) string {
	days, ok := escalationTiers[tier]
	if !ok {
		days = escalationTiers["free"]
	}
	b, _ := json.Marshal(days)
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

// validateLadderDays:days 至少 1 个正整数,≤10 个。
func validateLadderDays(days []int) string {
	if len(days) < 1 || len(days) > 10 {
		return "days must contain 1 to 10 entries"
	}
	for _, d := range days {
		if d <= 0 {
			return "days must be positive integers"
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
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		defer rows.Close()
		list := []ladderJSON{}
		for rows.Next() {
			var l ladderJSON
			var days string
			if err := rows.Scan(&l.ID, &l.Name, &l.IsGlobal, &days, &l.CreatedAt); err != nil {
				log.Printf("scan ladder: %v", err)
				writeError(w, http.StatusInternalServerError, "internal error")
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
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		if strings.TrimSpace(req.Name) == "" {
			writeError(w, http.StatusBadRequest, "name is required")
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
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		id, _ := res.LastInsertId()
		logAudit(db, uid, "新增触发阶梯", map[string]any{"id": id, "name": req.Name, "days": req.Days})
		l, err := scanLadder(db.QueryRow(`SELECT id, name, is_global, days, created_at FROM trigger_ladders WHERE id = ?`, id))
		if err != nil {
			log.Printf("fetch ladder: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
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
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
		var req ladderRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		if strings.TrimSpace(req.Name) == "" {
			writeError(w, http.StatusBadRequest, "name is required")
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
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeError(w, http.StatusNotFound, "ladder not found")
			return
		}
		logAudit(db, uid, "修改触发阶梯", map[string]any{"id": id, "name": req.Name, "days": req.Days})
		l, err := scanLadder(db.QueryRow(`SELECT id, name, is_global, days, created_at FROM trigger_ladders WHERE id = ?`, id))
		if err != nil {
			log.Printf("fetch ladder: %v", err)
			writeError(w, http.StatusInternalServerError, "internal error")
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
			writeError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		if len(req.IDs) == 0 {
			writeError(w, http.StatusBadRequest, "ids required")
			return
		}
		deleted, skipped := 0, 0
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
			if _, err := db.Exec(`DELETE FROM trigger_ladders WHERE id = ? AND user_id = ?`, id, uid); err != nil {
				log.Printf("delete ladder: %v", err)
				continue
			}
			deleted++
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
		logAudit(db, uid, "删除触发阶梯", map[string]any{"deleted": deleted, "skipped": skipped})
		writeJSON(w, http.StatusOK, map[string]int{"deleted": deleted, "skipped": skipped})
	}
}