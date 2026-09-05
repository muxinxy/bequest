-- 015_activity_logs.sql: 审计日志 + 应用日志统一入 audit_logs
-- kind: 'audit' = 重要操作(审计日志); 'app' = 所有操作(应用日志)
-- action 为中文描述;detail 存 JSON 补充信息(目标 id/名称等)
-- 既有 audit_logs 表(actor/action/detail/created_at)增加 kind 列,默认 audit 兼容旧数据
ALTER TABLE audit_logs ADD COLUMN kind TEXT NOT NULL DEFAULT 'audit' CHECK (kind IN ('audit', 'app'));

CREATE INDEX idx_audit_logs_user_time ON audit_logs(user_id, created_at);
