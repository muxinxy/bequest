-- 026_captcha_store.sql: 图形验证码持久化。
-- 答案哈希原存进程内存(单实例假设), 改存 DB: 重启不失效、多实例部署可用。
-- expires_at 为 UTC 文本时间戳, 与全库一致走字符串比较。
CREATE TABLE IF NOT EXISTS captchas (
    id VARCHAR(32) PRIMARY KEY,
    answer_hash VARCHAR(64) NOT NULL,
    expires_at VARCHAR(19) NOT NULL
);
