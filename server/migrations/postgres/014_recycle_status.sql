-- 014_recycle_status.sql: 回收站 + 资产状态 + 分组备注
-- 资产状态:active(正常,默认)/inactive(停用)/pending(待处理)/expired(已过期,由到期日派生)
-- 软删除:deleted_at 非空 = 在回收站(资产与分组通用)

ALTER TABLE assets ADD COLUMN deleted_at VARCHAR(19);
ALTER TABLE assets ADD COLUMN status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive','pending','expired'));

ALTER TABLE categories ADD COLUMN remark TEXT;
ALTER TABLE categories ADD COLUMN deleted_at VARCHAR(19);

CREATE INDEX idx_assets_deleted ON assets(user_id, deleted_at);
CREATE INDEX idx_categories_deleted ON categories(user_id, deleted_at);
