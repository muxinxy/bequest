-- 继承事件 + 提醒表 + 系统默认提醒模板（继承交接死信箱）

-- 继承事件：一次触发 = 一个待领取交接（含快照的访问码哈希）
CREATE TABLE inheritance_events (
    id               BIGSERIAL PRIMARY KEY,
    user_id          BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    inheritor_id     BIGINT NOT NULL REFERENCES inheritors(id),
    event_key        TEXT NOT NULL UNIQUE,
    status           TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','claimed','reversed')),
    access_code_hash TEXT NOT NULL,
    created_at       VARCHAR(19) NOT NULL DEFAULT (to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS')),
    claimed_at       VARCHAR(19),
    reversed_at      VARCHAR(19)
);

-- 提醒（expiry=到期 / escalation=不活跃升级 / inheritance=继承交接触发）
CREATE TABLE reminders (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type       TEXT NOT NULL CHECK (type IN ('expiry','escalation','inheritance')),
    asset_id   BIGINT REFERENCES assets(id) ON DELETE CASCADE,
    title      TEXT NOT NULL,
    body       TEXT NOT NULL,
    dedup_key  TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','read')),
    created_at VARCHAR(19) NOT NULL DEFAULT (to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS'))
);

CREATE UNIQUE INDEX idx_reminders_dedup ON reminders(user_id, dedup_key);
CREATE INDEX idx_events_user ON inheritance_events(user_id, status);

-- 系统默认提醒模板（user_id NULL = 系统级，不可编辑/删除）
INSERT INTO reminder_templates (name, title_template, body_template, is_preset) VALUES
    ('过期提醒', '资产「{name}」即将到期', '您的资产 {name} 将于 {date} 到期,请及时处理续费或迁移。', 1),
    ('继承交接', '继承交接已触发', '您的继承交接流程已触发,如您仍然在世,请立即登录以取消。', 1),
    ('不活跃提醒', '长时间未登录提醒', '您已 {days} 天未登录,资产安全提醒升级。', 1);
