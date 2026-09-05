package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
)

// ---------- 继承触发预览 ----------

type previewAsset struct {
	ID            int64  `json:"id"`
	Name          string `json:"name"`
	InheritorName string `json:"inheritor_name"`
	InheritorID   *int64 `json:"inheritor_id"`
	Via           string `json:"via"` // 'asset' | 'category' | 'user'
}

type previewInheritor struct {
	ID         int64  `json:"id"`
	Name       string `json:"name"`
	Email      string `json:"email"`
	Phone      string `json:"phone"`
	AssetCount int    `json:"asset_count"`
}

type previewLadder struct {
	Days     []int  `json:"days"`
	IsGlobal bool   `json:"is_global"`
	Name     string `json:"name"`
}

// handleInheritancePreview: GET /api/v1/inheritance/preview -> 200
// 返回继承触发预览:阶梯、触发天数、资产映射(asset/category/user)、继承人及覆盖数。
func handleInheritancePreview(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)

		// 阶梯:读全局阶梯(无则补建),days 取最后档为触发天数。
		ladderID := ensureGlobalLadder(db, uid)
		ladder := previewLadder{IsGlobal: true, Name: "全局", Days: defaultLadderConfig}
		if ladderID > 0 {
			var name, days string
			if err := db.QueryRow(`SELECT name, days FROM trigger_ladders WHERE id = ?`, ladderID).
				Scan(&name, &days); err == nil {
				var d []int
				if json.Unmarshal([]byte(days), &d) == nil && len(d) > 0 {
					ladder.Days = d
				}
				ladder.Name = name
			}
		}
		triggerDays := ladder.Days[len(ladder.Days)-1]

		// 全部资产。
		rows, err := db.Query(`SELECT id, name, category_id FROM assets WHERE user_id = ? AND status = 'active' ORDER BY id`, uid)
		if err != nil {
			log.Printf("preview assets: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		type assetRow struct {
			id         int64
			name       string
			categoryID sql.NullInt64
		}
		var assets []assetRow
		for rows.Next() {
			var a assetRow
			if err := rows.Scan(&a.id, &a.name, &a.categoryID); err != nil {
				log.Printf("scan preview asset: %v", err)
				rows.Close()
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			assets = append(assets, a)
		}
		rows.Close()

		// 资产级绑定:每资产取 priority 最小的继承人。
		assetInheritor := map[int64]int64{} // asset_id -> inheritor_id
		arows, err := db.Query(`SELECT ai.asset_id, ai.inheritor_id
			FROM asset_inheritors ai JOIN assets a ON a.id = ai.asset_id
			WHERE a.user_id = ? ORDER BY ai.priority ASC, ai.id ASC`, uid)
		if err != nil {
			log.Printf("preview asset inheritors: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		for arows.Next() {
			var aid, iid int64
			if err := arows.Scan(&aid, &iid); err != nil {
				log.Printf("scan asset inheritor: %v", err)
				arows.Close()
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if _, ok := assetInheritor[aid]; !ok {
				assetInheritor[aid] = iid
			}
		}
		arows.Close()

		// 分组级绑定:每分组取 priority 最小的继承人。
		categoryInheritor := map[int64]int64{} // category_id -> inheritor_id
		crows, err := db.Query(`SELECT ci.category_id, ci.inheritor_id
			FROM category_inheritors ci JOIN categories c ON c.id = ci.category_id
			WHERE c.user_id = ? ORDER BY ci.priority ASC, ci.id ASC`, uid)
		if err != nil {
			log.Printf("preview category inheritors: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		for crows.Next() {
			var cid, iid int64
			if err := crows.Scan(&cid, &iid); err != nil {
				log.Printf("scan category inheritor: %v", err)
				crows.Close()
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			if _, ok := categoryInheritor[cid]; !ok {
				categoryInheritor[cid] = iid
			}
		}
		crows.Close()

		// 继承人信息。
		inheritorInfo := map[int64]previewInheritor{}
		irows, err := db.Query(`SELECT id, name, COALESCE(email, ''), COALESCE(phone, '') FROM inheritors WHERE user_id = ?`, uid)
		if err != nil {
			log.Printf("preview inheritors: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		for irows.Next() {
			var p previewInheritor
			if err := irows.Scan(&p.ID, &p.Name, &p.Email, &p.Phone); err != nil {
				log.Printf("scan inheritor: %v", err)
				irows.Close()
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
				return
			}
			inheritorInfo[p.ID] = p
		}
		irows.Close()

		// 资产映射 + 继承人覆盖计数。
		userLevel := map[int64]bool{} // 走用户级全量事件的继承人(未绑定资产/分组的资产)
		inheritorCount := map[int64]int{}
		preview := make([]previewAsset, 0, len(assets))
		for _, a := range assets {
			pa := previewAsset{ID: a.id, Name: a.name}
			if iid, ok := assetInheritor[a.id]; ok {
				pa.Via = "asset"
				pa.InheritorID = &iid
				pa.InheritorName = inheritorInfo[iid].Name
				inheritorCount[iid]++
			} else if a.categoryID.Valid {
				if iid, ok := categoryInheritor[a.categoryID.Int64]; ok {
					pa.Via = "category"
					pa.InheritorID = &iid
					pa.InheritorName = inheritorInfo[iid].Name
					inheritorCount[iid]++
				} else {
					pa.Via = "user"
					userLevel[0] = true // 标记存在用户级全量资产
				}
			} else {
				pa.Via = "user"
				userLevel[0] = true
			}
			preview = append(preview, pa)
		}

		// 用户级全量事件:优先用默认继承人;未设置(或指向已删除继承人)时回退第一顺位。
		var userLevelInheritors []string
		if userLevel[0] {
			var iid int64
			var name string
			var defID sql.NullInt64
			if err := db.QueryRow(`SELECT default_inheritor_id FROM users WHERE id = ?`, uid).Scan(&defID); err == nil && defID.Valid {
				if err := db.QueryRow(`SELECT id, name FROM inheritors WHERE id = ? AND user_id = ?`, defID.Int64, uid).
					Scan(&iid, &name); err == nil {
					userLevelInheritors = append(userLevelInheritors, name)
					inheritorCount[iid]++
				}
			}
			if len(userLevelInheritors) == 0 {
				if err := db.QueryRow(`SELECT id, name FROM inheritors WHERE user_id = ? ORDER BY priority ASC, id ASC LIMIT 1`, uid).
					Scan(&iid, &name); err == nil {
					userLevelInheritors = append(userLevelInheritors, name)
					inheritorCount[iid]++
				}
			}
		}

		// 继承人列表(按 id 排序)。
		inheritors := make([]previewInheritor, 0, len(inheritorInfo))
		for _, p := range inheritorInfo {
			p.AssetCount = inheritorCount[p.ID]
			inheritors = append(inheritors, p)
		}

		note := "失联超过触发阶梯末档后将触发继承:资产级绑定的资产交接给指定继承人,其余资产按用户级全量事件交接。继承人凭继承码领取密钥,原主登录可在 72 小时内撤销。"

		writeJSON(w, http.StatusOK, map[string]any{
			"ladder":                ladder,
			"trigger_days":          triggerDays,
			"total_assets":          len(assets),
			"inherited_assets":      len(assets),
			"assets":                preview,
			"inheritors":            inheritors,
			"user_level_inheritors": userLevelInheritors,
			"note":                  note,
		})
	}
}

// handleGetDefaultInheritor: GET /api/v1/inheritance/default-inheritor -> 200// 返回默认继承人;未设置时 inheritor_id 为 null。
func handleGetDefaultInheritor(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var defID sql.NullInt64
		var name string
		if err := db.QueryRow(`SELECT default_inheritor_id FROM users WHERE id = ?`, uid).Scan(&defID); err != nil {
			log.Printf("get default inheritor: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		if defID.Valid {
			// 指向已删除继承人时视为未设置。
			if err := db.QueryRow(`SELECT name FROM inheritors WHERE id = ? AND user_id = ?`, defID.Int64, uid).
				Scan(&name); err != nil {
				defID.Valid = false
			}
		}
		var id *int64
		if defID.Valid {
			v := defID.Int64
			id = &v
		}
		writeJSON(w, http.StatusOK, map[string]any{"inheritor_id": id, "inheritor_name": name})
	}
}

// handlePutDefaultInheritor: PUT /api/v1/inheritance/default-inheritor
// body {"inheritor_id": 5} 或 {"inheritor_id": null}(null=不指定,回退第一顺位)。
// 非空时须属于该用户,否则 400。
func handlePutDefaultInheritor(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid := userID(r)
		var body struct {
			InheritorID *int64 `json:"inheritor_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeError(w, http.StatusBadRequest, "请求格式错误")
			return
		}
		if body.InheritorID != nil {
			var n int
			if err := db.QueryRow(`SELECT COUNT(*) FROM inheritors WHERE id = ? AND user_id = ?`, *body.InheritorID, uid).
				Scan(&n); err != nil || n == 0 {
				writeError(w, http.StatusBadRequest, "继承人不存在或不属于该用户")
				return
			}
		}
		var defID any
		if body.InheritorID != nil {
			defID = *body.InheritorID
		}
		if _, err := db.Exec(`UPDATE users SET default_inheritor_id = ? WHERE id = ?`, defID, uid); err != nil {
			log.Printf("set default inheritor: %v", err)
			writeError(w, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"default_inheritor_id": body.InheritorID})
	}
}
