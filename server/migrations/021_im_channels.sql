-- 021_im_channels.sql: 通知渠道扩展 IM webhook(企业微信/钉钉/飞书)
-- SQLite 改 CHECK 需重建表;原数据(邮箱/手机号)原样保留。
CREATE TABLE notification_channels_new (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type       TEXT NOT NULL CHECK (type IN ('email','phone','wecom','dingtalk','feishu')),
    value      TEXT NOT NULL,               -- 邮箱/手机号/IM webhook URL
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
INSERT INTO notification_channels_new (id, user_id, type, value, sort_order, created_at)
    SELECT id, user_id, type, value, sort_order, created_at FROM notification_channels;
DROP TABLE notification_channels;
ALTER TABLE notification_channels_new RENAME TO notification_channels;
CREATE INDEX idx_notification_channels_user ON notification_channels(user_id);
