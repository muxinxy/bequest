-- 008_password_reset.sql: 忘记密码(邮箱验证码)重置
-- 验证码表:code 哈希存储(防泄露),10 分钟过期,一次性。
CREATE TABLE password_resets (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash  TEXT NOT NULL,               -- sha256(验证码)
    expires_at VARCHAR(19) NOT NULL,        -- UTC datetime
    used       INTEGER NOT NULL DEFAULT 0,
    created_at VARCHAR(19) NOT NULL DEFAULT (to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS'))
);
CREATE INDEX idx_password_resets_user ON password_resets(user_id);
