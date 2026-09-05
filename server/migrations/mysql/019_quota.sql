CREATE TABLE notification_quota (
    id        BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id   BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    month     VARCHAR(7) NOT NULL,          -- "2026-08"
    email_cnt INT NOT NULL DEFAULT 0,
    sms_cnt   INT NOT NULL DEFAULT 0,
    UNIQUE (user_id, month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
