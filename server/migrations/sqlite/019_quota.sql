CREATE TABLE notification_quota (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id   INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    month     TEXT NOT NULL,            -- "2026-08"
    email_cnt INTEGER NOT NULL DEFAULT 0,
    sms_cnt   INTEGER NOT NULL DEFAULT 0,
    UNIQUE (user_id, month)
);