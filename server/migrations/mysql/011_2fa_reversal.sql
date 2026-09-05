-- 管理后台 TOTP 2FA + 继承交接 72h 反悔期
ALTER TABLE users ADD COLUMN totp_secret TEXT;
ALTER TABLE inheritance_events ADD COLUMN reversable_until VARCHAR(19) NULL;
