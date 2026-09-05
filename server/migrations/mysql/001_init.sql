-- 托孤 (bequest) 初始建库脚本（MySQL）
-- 敏感数据均为客户端加密后的密文，服务端不存明文。

-- 用户（含继承状态字段，1:1）
CREATE TABLE users (
    id                BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    username          VARCHAR(191) NOT NULL UNIQUE,
    email             VARCHAR(191) NOT NULL UNIQUE,
    password_hash     TEXT NOT NULL,                -- argon2id
    master_key_wrapped LONGBLOB,                    -- 主密钥被服务端包装密钥封装，用于继承发放（方案 A）
    tier              TEXT NOT NULL DEFAULT ('free') CHECK (tier IN ('free','member')),
    inherit_stage     TEXT NOT NULL DEFAULT ('inactive')
                      CHECK (inherit_stage IN ('inactive','warning','triggered','claimed','reversed')),
    escalation_level  INT NOT NULL DEFAULT 0,       -- 不登录升级阶梯当前档位
    last_login_at     VARCHAR(19) NULL,
    created_at        VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP()),
    updated_at        VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP())
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 继承人（每用户多个；priority 预留多继承人顺延）
CREATE TABLE inheritors (
    id               BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id          BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name             TEXT NOT NULL,
    email            TEXT NOT NULL,
    access_code_hash VARCHAR(64) NOT NULL,          -- 预设访问码（哈希存储）
    priority         INT NOT NULL DEFAULT 1,
    created_at       VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP())
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 分类（预设分类 is_preset=1 不可删除）
CREATE TABLE categories (
    id         BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       VARCHAR(255) NOT NULL,
    is_preset  INT NOT NULL DEFAULT 0,
    created_at VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP()),
    UNIQUE (user_id, name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 资产（name 明文便于列表；敏感字段整体 AES-256-GCM 密文）
CREATE TABLE assets (
    id                BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id           BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category_id       BIGINT REFERENCES categories(id) ON DELETE SET NULL,
    asset_type        TEXT NOT NULL CHECK (asset_type IN ('physical','virtual')),
    name              TEXT NOT NULL,
    encrypted_data    LONGBLOB NOT NULL,            -- 凭据/备注/关键描述（密文）
    expiry_date       VARCHAR(10),                  -- 到期/续费日
    reminder_settings TEXT NOT NULL DEFAULT ('{}'), -- JSON：提前天数/渠道/模板引用
    created_at        VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP()),
    updated_at        VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP())
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 提醒模板（user_id NULL = 系统默认模板）
CREATE TABLE reminder_templates (
    id             BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id        BIGINT REFERENCES users(id) ON DELETE CASCADE,
    name           TEXT NOT NULL,
    title_template TEXT NOT NULL,
    body_template  TEXT NOT NULL,
    is_preset      INT NOT NULL DEFAULT 0,
    created_at     VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP())
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 审计日志（谁、何时、做了什么）
CREATE TABLE audit_logs (
    id         BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id    BIGINT NOT NULL,
    actor      TEXT NOT NULL,                       -- 'owner' / 'inheritor:<id>' / 'system'
    action     TEXT NOT NULL,
    detail     TEXT,
    created_at VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP())
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE INDEX idx_assets_user ON assets(user_id);
CREATE INDEX idx_inheritors_user ON inheritors(user_id);
CREATE INDEX idx_audit_user ON audit_logs(user_id, created_at);
