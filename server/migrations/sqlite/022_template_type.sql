-- 022_template_type.sql: 提醒模板加类型(expiry/escalation/inheritance)
-- 预设模板按 name 回填 type(002 迁移已插入的存量行)。
ALTER TABLE reminder_templates ADD COLUMN type TEXT NOT NULL DEFAULT 'expiry'
    CHECK (type IN ('expiry','escalation','inheritance'));
UPDATE reminder_templates SET type='expiry' WHERE name='过期提醒';
UPDATE reminder_templates SET type='inheritance' WHERE name='继承交接';
UPDATE reminder_templates SET type='escalation' WHERE name='不活跃提醒';