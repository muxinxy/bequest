-- 管理后台：用户角色 + 禁用标记
ALTER TABLE users ADD COLUMN role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user','admin'));
ALTER TABLE users ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0;
