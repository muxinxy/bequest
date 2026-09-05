CREATE TABLE notification_quota (
    id        BIGSERIAL PRIMARY KEY,
    user_id   BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    month     TEXT NOT NULL,            -- "2026-08"
    email_cnt INTEGER NOT NULL DEFAULT 0,
    sms_cnt   INTEGER NOT NULL DEFAULT 0,
    UNIQUE (user_id, month)
);
