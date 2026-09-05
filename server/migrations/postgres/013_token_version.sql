-- 账户安全:改密后旧 token 失效(token_version) + 重置验证码尝试计数
ALTER TABLE users ADD COLUMN token_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE password_resets ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
