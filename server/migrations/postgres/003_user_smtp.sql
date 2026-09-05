-- 用户自定义 SMTP（隐私敏感用户可自建邮件服务器接收提醒）
-- password_enc: AES-256-GCM 密文(nonce||ciphertext||tag),密钥见 ENCRYPTION_KEY
CREATE TABLE user_smtp (
    user_id      BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    host         TEXT NOT NULL,
    port         INTEGER NOT NULL DEFAULT 587,
    "user"       TEXT NOT NULL DEFAULT '',
    password_enc BYTEA NOT NULL,
    from_addr    TEXT NOT NULL DEFAULT '',
    enabled      INTEGER NOT NULL DEFAULT 1,
    updated_at   VARCHAR(19) NOT NULL DEFAULT (to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS'))
);
