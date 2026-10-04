package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// restoreDialect 测试后恢复全局方言,避免影响其他用例
// (openDB 会按 DB_DRIVER 重设 currentDialect)。
func restoreDialect(t *testing.T) {
	old := currentDialect
	t.Cleanup(func() { currentDialect = old })
}

func TestOpenDBUsesDataDir(t *testing.T) {
	restoreDialect(t)

	tmp := t.TempDir()
	t.Chdir(tmp) // 隔离 CWD:避免包目录下真实的 server/data 开发库触发升级保护
	dir := filepath.Join(tmp, "custom", "nested")
	t.Setenv("DB_DRIVER", "sqlite")
	t.Setenv("DATA_DIR", dir)

	db, err := openDB()
	if err != nil {
		t.Fatalf("open database with DATA_DIR: %v", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		t.Fatalf("ping database with DATA_DIR: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close database with DATA_DIR: %v", err)
	}

	if _, err := os.Stat(filepath.Join(dir, "bequest.db")); err != nil {
		t.Fatalf("database was not created under DATA_DIR: %v", err)
	}
}

// TestOpenDBRejectsLegacyDataDir 锁定升级保护:旧版本忽略 DATA_DIR、一律用
// CWD 下的 data/bequest.db;新版本读到显式 DATA_DIR 且目标库不存在、而旧路径
// 库存在时必须拒绝启动,防止静默在新目录建一套空库。
func TestOpenDBRejectsLegacyDataDir(t *testing.T) {
	restoreDialect(t)

	tmp := t.TempDir()
	t.Chdir(tmp) // 旧版实际库位置相对 CWD
	if err := os.MkdirAll("data", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join("data", "bequest.db"), []byte("legacy"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DB_DRIVER", "sqlite")
	t.Setenv("DATA_DIR", filepath.Join(tmp, "elsewhere"))

	_, err := openDB()
	if err == nil {
		t.Fatal("expected openDB to refuse: DATA_DIR db missing but legacy data/bequest.db exists")
	}
	if !strings.Contains(err.Error(), "DATA_DIR") {
		t.Fatalf("error should mention DATA_DIR, got: %v", err)
	}
}

// TestOpenDBWarnsWhenLegacyDataDirAlsoExists:两个库都在时应正常启动
// (仅打印警告),不能误拒。
func TestOpenDBWarnsWhenLegacyDataDirAlsoExists(t *testing.T) {
	restoreDialect(t)

	tmp := t.TempDir()
	t.Chdir(tmp)
	if err := os.MkdirAll("data", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join("data", "bequest.db"), []byte("legacy"), 0o600); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(tmp, "dd")
	if err := os.MkdirAll(target, 0o700); err != nil {
		t.Fatal(err)
	}
	// 零字节文件是合法的空 SQLite 库(SQLite 会自动初始化),满足"两库共存"。
	if err := os.WriteFile(filepath.Join(target, "bequest.db"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DB_DRIVER", "sqlite")
	t.Setenv("DATA_DIR", target)

	db, err := openDB()
	if err != nil {
		t.Fatalf("openDB should proceed when both databases exist: %v", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		t.Fatalf("ping: %v", err)
	}
	db.Close()
}

// TestOpenDBDataDirSpecialCharsAndPerms:DATA_DIR 含 URI 特殊字符时必须
// 打开到正确路径(file: URI 按 ? # % 解析,不转义会错位);Unix 上目录
// 权限应为 0700(数据含账号/密码哈希等敏感信息)。
func TestOpenDBDataDirSpecialCharsAndPerms(t *testing.T) {
	restoreDialect(t)
	t.Setenv("DB_DRIVER", "sqlite")

	dirs := []string{"data dir", "数据 目录"}
	if runtime.GOOS != "windows" {
		// Windows 文件名不允许 ? " 等;Unix 上是合法且易踩坑的名字。
		dirs = append(dirs, "da#ta?dir%1", "d'ata\"dir")
	}
	for _, name := range dirs {
		tmp := t.TempDir()
		t.Chdir(tmp) // 隔离 CWD,避免触发旧库升级保护
		dir := filepath.Join(tmp, name)
		t.Setenv("DATA_DIR", dir)

		db, err := openDB()
		if err != nil {
			t.Fatalf("openDB with DATA_DIR %q: %v", name, err)
		}
		if err := db.Ping(); err != nil {
			db.Close()
			t.Fatalf("ping with DATA_DIR %q: %v", name, err)
		}
		db.Close()
		if _, err := os.Stat(filepath.Join(dir, "bequest.db")); err != nil {
			t.Fatalf("db not created under %q: %v", name, err)
		}
		if runtime.GOOS != "windows" {
			if fi, err := os.Stat(dir); err != nil || fi.Mode().Perm() != 0o700 {
				t.Fatalf("dir %q perm = %v, want 0700", name, fi.Mode().Perm())
			}
		}
	}
}

func TestEmbeddedMigrationsAreAvailable(t *testing.T) {
	entries, err := sqliteMigrationFS.ReadDir(".")
	if err != nil {
		t.Fatalf("read embedded sqlite migrations: %v", err)
	}
	if len(entries) == 0 {
		t.Fatal("embedded sqlite migrations are empty")
	}
	if n, _ := mysqlMigrationFS.ReadDir("."); len(n) == 0 {
		t.Fatal("embedded mysql migrations are empty")
	}
	if n, _ := postgresMigrationFS.ReadDir("."); len(n) == 0 {
		t.Fatal("embedded postgres migrations are empty")
	}
}

// TestSplitStatements guards the migration statement splitter used for
// MySQL/PostgreSQL (which execute per-statement).
func TestSplitStatements(t *testing.T) {
	body := `-- comment line
CREATE TABLE a (id INTEGER PRIMARY KEY);
CREATE TABLE b (
  id INTEGER PRIMARY KEY,
  x TEXT NOT NULL DEFAULT (datetime('now'))
);
INSERT INTO b (x) VALUES ('semi;colon in literal? no');
`
	stmts := splitStatements(body)
	if len(stmts) != 3 {
		t.Fatalf("want 3 statements, got %d: %q", len(stmts), stmts)
	}
	for _, s := range stmts {
		if len(s) == 0 {
			t.Fatal("empty statement produced")
		}
	}
}
