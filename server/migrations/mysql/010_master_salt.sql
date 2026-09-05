-- 跨设备登录恢复:注册时上传主密码盐(明文不敏感,ADR-11),
-- 新设备登录时客户端用「主密码 + 盐」重新派生主密钥(非破坏性恢复)。
ALTER TABLE users ADD COLUMN master_salt TEXT;
