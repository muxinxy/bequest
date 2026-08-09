-- 分类增加类型（实体/虚拟）。is_preset 列在 001_init.sql 已存在，此处只加 asset_type。
-- SQLite ADD COLUMN 允许带 CHECK + 非空默认值（现有行回填 'physical'）。
ALTER TABLE categories ADD COLUMN asset_type TEXT NOT NULL DEFAULT 'physical' CHECK (asset_type IN ('physical','virtual'));
