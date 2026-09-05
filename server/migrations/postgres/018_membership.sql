-- 会员体系:到期时间 + 兑换码
ALTER TABLE users ADD COLUMN member_expires_at VARCHAR(19);
CREATE TABLE redemption_codes (
    id            BIGSERIAL PRIMARY KEY,
    code          TEXT NOT NULL UNIQUE,
    duration_days INTEGER NOT NULL,             -- 兑换后会员时长(天)
    used_by       BIGINT REFERENCES users(id),  -- 使用人;NULL=未用
    used_at       VARCHAR(19),
    created_by    BIGINT NOT NULL,              -- 生成人(admin 用户 id)
    created_at    VARCHAR(19) NOT NULL DEFAULT (to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS'))
);
CREATE INDEX idx_redemption_codes_used ON redemption_codes(used_at);
