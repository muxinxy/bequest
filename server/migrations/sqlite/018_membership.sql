-- 会员体系:到期时间 + 兑换码
ALTER TABLE users ADD COLUMN member_expires_at TEXT;
CREATE TABLE redemption_codes (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    code          TEXT NOT NULL UNIQUE,
    duration_days INTEGER NOT NULL,             -- 兑换后会员时长(天)
    used_by       INTEGER REFERENCES users(id), -- 使用人;NULL=未用
    used_at       TEXT,
    created_by    INTEGER NOT NULL,             -- 生成人(admin 用户 id)
    created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_redemption_codes_used ON redemption_codes(used_at);