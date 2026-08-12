-- 008_password_reset.sql: 忘记密码(邮箱验证码)重置
-- 验证码表:code 哈希存储(防泄露),10 分钟过期,一次性。
CREATE TABLE password_resets (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash  TEXT NOT NULL,               -- sha256(验证码)
    expires_at TEXT NOT NULL,               -- UTC datetime
    used       INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_password_resets_user ON password_resets(user_id);
