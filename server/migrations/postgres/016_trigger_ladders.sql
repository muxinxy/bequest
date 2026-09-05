-- 016_trigger_ladders.sql: 触发阶梯(用户级可配置) + 继承绑定引用阶梯 + 继承码明文
-- 触发阶梯:每用户一条全局阶梯(is_global=1,不可删)+ 多条自定义阶梯;
-- days 存 JSON 数组(如 "[30,60,90,120]"),替代 scheduler 里硬编码的 escalationTiers。
CREATE TABLE trigger_ladders (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       TEXT   NOT NULL,
    is_global  INTEGER NOT NULL DEFAULT 0,  -- 1=全局阶梯(每用户一条,不可删)
    days       TEXT   NOT NULL,             -- JSON 数组,如 "[30,60,90,120]"
    created_at VARCHAR(19) NOT NULL DEFAULT (to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS'))
);
CREATE INDEX idx_trigger_ladders_user ON trigger_ladders(user_id);

-- 继承绑定引用阶梯(NULL=全局)
ALTER TABLE asset_inheritors ADD COLUMN ladder_id BIGINT REFERENCES trigger_ladders(id) ON DELETE SET NULL;
ALTER TABLE category_inheritors ADD COLUMN ladder_id BIGINT REFERENCES trigger_ladders(id) ON DELETE SET NULL;

-- 继承码明文(用户本人可查看;claim 验证仍用 access_code_hash)
ALTER TABLE inheritors ADD COLUMN access_code TEXT;
