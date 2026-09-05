-- 020_admin_login_lock.sql: 管理员账号登录失败锁定
-- 连续失败 5 次锁定 5 分钟,防后台暴力爆破(普通用户不启用)。
ALTER TABLE users ADD COLUMN login_fail_count INT NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN locked_until VARCHAR(19) NULL;
