-- 分组自定义排序(0 = 最先)
ALTER TABLE categories ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;
