-- 007_category_inheritors.sql: 分组(分类)级继承人
-- 分组绑定的继承人 = 该分组下所有资产的默认继承人(资产级绑定优先级更高)。
CREATE TABLE category_inheritors (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    category_id  INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
    inheritor_id INTEGER NOT NULL REFERENCES inheritors(id) ON DELETE CASCADE,
    priority     INTEGER NOT NULL DEFAULT 1,
    trigger_days INTEGER,           -- 独立触发天数;NULL=沿用全局升级阶梯
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (category_id, inheritor_id)
);
CREATE INDEX idx_category_inheritors_cat ON category_inheritors(category_id);
CREATE INDEX idx_category_inheritors_inheritor ON category_inheritors(inheritor_id);
