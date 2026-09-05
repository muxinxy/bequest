-- 024_template_default.sql: 提醒模板加"默认模板"标记。
-- 存量数据不在此回填:查询/创建时兜底(首个自定义模板按 id 升序视为默认)。
ALTER TABLE reminder_templates ADD COLUMN is_default INTEGER NOT NULL DEFAULT 0;
