-- 会员体系:到期时间 + 兑换码
ALTER TABLE users ADD COLUMN member_expires_at VARCHAR(19) NULL;
CREATE TABLE redemption_codes (
    id            BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    code          VARCHAR(255) NOT NULL UNIQUE,
    duration_days INT NOT NULL,             -- 兑换后会员时长(天)
    used_by       BIGINT REFERENCES users(id), -- 使用人;NULL=未用
    used_at       VARCHAR(19) NULL,
    created_by    BIGINT NOT NULL,          -- 生成人(admin 用户 id)
    created_at    VARCHAR(19) NOT NULL DEFAULT (UTC_TIMESTAMP())
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX idx_redemption_codes_used ON redemption_codes(used_at);
