-- 025_user_lang.sql: 用户界面语言偏好(zh/en,默认中文)。
-- 调度器提醒/邮件等服务端生成的用户可见文案按此偏好输出。
ALTER TABLE users ADD COLUMN lang VARCHAR(8) NOT NULL DEFAULT 'zh';
