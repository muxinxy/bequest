-- 006_inheritance_toggle.sql: 全局继承开关
-- inheritance_enabled = 0 时调度器跳过升级提醒与继承触发(1=开启,默认)。
ALTER TABLE users ADD COLUMN inheritance_enabled INT NOT NULL DEFAULT 1;
