-- 021_im_channels.sql: 通知渠道扩展 IM webhook(企业微信/钉钉/飞书)
-- PostgreSQL 改 CHECK 需重建表;原数据(邮箱/手机号)原样保留。
CREATE TABLE notification_channels_new (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type       TEXT NOT NULL CHECK (type IN ('email','phone','wecom','dingtalk','feishu')),
    value      TEXT NOT NULL,               -- 邮箱/手机号/IM webhook URL
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at VARCHAR(19) NOT NULL DEFAULT (to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS'))
);
INSERT INTO notification_channels_new (id, user_id, type, value, sort_order, created_at)
    SELECT id, user_id, type, value, sort_order, created_at FROM notification_channels;
DROP TABLE notification_channels;
ALTER TABLE notification_channels_new RENAME TO notification_channels;
CREATE INDEX idx_notification_channels_user ON notification_channels(user_id);
SELECT setval(pg_get_serial_sequence('notification_channels', 'id'), COALESCE((SELECT MAX(id) FROM notification_channels), 1));
