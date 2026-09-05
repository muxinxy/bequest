-- 默认继承人:用户级全量继承事件优先交接给该继承人;未设置(或指向已删除继承人)时回退第一顺位。
ALTER TABLE users ADD COLUMN default_inheritor_id INTEGER REFERENCES inheritors(id);
