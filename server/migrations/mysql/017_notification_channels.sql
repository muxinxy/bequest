-- 017_notification_channels.sql: 通知渠道(邮箱/手机号) + 短信提供商 + 继承人手机号
-- 通知渠道:每用户最多各 3 个邮箱/手机号,按 sort_order 排序发送。
CREATE TABLE notification_channels (
    id         BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type       TEXT NOT NULL CHECK (type IN ('email','phone')),
    value      TEXT NOT NULL,               -- 邮箱地址或手机号
    sort_order INT NOT NULL DEFAULT 0,
    created_at VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP())
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX idx_notification_channels_user ON notification_channels(user_id);

-- 短信提供商:enabled=1 的配置按轮询逐个尝试,成功即返回。
CREATE TABLE sms_providers (
    id           BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    provider     TEXT NOT NULL CHECK (provider IN ('tencent','aliyun')),
    name         TEXT NOT NULL,             -- 配置名称(如"腾讯云主账号")
    access_key   TEXT NOT NULL,
    secret_key   TEXT NOT NULL,
    extra        TEXT,                      -- JSON:腾讯{sdk_app_id,sign_name,template_id,region} 阿里{sign_name,template_code,endpoint}
    enabled      INT NOT NULL DEFAULT 1,
    created_at   VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP())
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 继承人手机号(可选;创建时邮箱或手机号至少一个)
ALTER TABLE inheritors ADD COLUMN phone TEXT;
