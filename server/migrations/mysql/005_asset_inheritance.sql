-- 005_asset_inheritance.sql: 资产级密钥隔离 + 每资产继承人
-- 1) assets 增加资产密钥包装列:
--    - asset_key_wrapped_mk = AES-GCM(主密钥 MK, 资产密钥 AK)  号主解密用
--    - asset_key_wrapped_wk = AES-GCM(继承包装密钥 WK, 资产密钥 AK)  指定继承人解密用
--    旧资产(两列为 NULL)由客户端回退为直接用 MK 解密,渐进兼容不强制迁移。
ALTER TABLE assets ADD COLUMN asset_key_wrapped_mk TEXT;
ALTER TABLE assets ADD COLUMN asset_key_wrapped_wk TEXT;

-- 2) 每资产继承人关联表:一个资产可指定多个继承人(priority 决定触发顺序)。
CREATE TABLE asset_inheritors (
    id          BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    asset_id    BIGINT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    inheritor_id BIGINT NOT NULL REFERENCES inheritors(id) ON DELETE CASCADE,
    priority    INT NOT NULL DEFAULT 1,
    trigger_days INT,           -- 独立触发天数(基于 last_login_at);NULL=沿用全局升级阶梯
    created_at  VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP()),
    UNIQUE (asset_id, inheritor_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX idx_asset_inheritors_asset ON asset_inheritors(asset_id);
CREATE INDEX idx_asset_inheritors_inheritor ON asset_inheritors(inheritor_id);

-- 3) 继承事件增加 asset_id(空=全量交接,现有行为)。
ALTER TABLE inheritance_events ADD COLUMN asset_id BIGINT REFERENCES assets(id) ON DELETE SET NULL;
CREATE INDEX idx_inheritance_events_asset ON inheritance_events(asset_id);
