-- 008_password_reset.sql: 忘记密码(邮箱验证码)重置
-- 验证码表:code 哈希存储(防泄露),10 分钟过期,一次性。
CREATE TABLE password_resets (
    id         BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash  VARCHAR(64) NOT NULL,        -- sha256(验证码)
    expires_at VARCHAR(19) NOT NULL,        -- UTC datetime
    used       INT NOT NULL DEFAULT 0,
    created_at VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP())
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX idx_password_resets_user ON password_resets(user_id);
