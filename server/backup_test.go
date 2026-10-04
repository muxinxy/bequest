package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRunBackup 覆盖 backup 子命令核心:默认按时间戳写 CWD;
// --output 路径含单引号时必须正确转义(VACUUM INTO 以 SQL 字面量拼接)。
func TestRunBackup(t *testing.T) {
	restoreDialect(t)

	tmp := t.TempDir()
	t.Chdir(tmp) // 默认输出落在 CWD(容器内即 /data 卷)
	t.Setenv("DB_DRIVER", "sqlite")
	t.Setenv("DATA_DIR", filepath.Join(tmp, "data"))

	db, err := openDB()
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()

	// 默认输出:CWD 下生成 bequest-backup-<时间戳>.db。
	if err := runBackup(db, ""); err != nil {
		t.Fatalf("default backup: %v", err)
	}
	entries, err := os.ReadDir(tmp)
	if err != nil {
		t.Fatal(err)
	}
	defaultFound := false
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "bequest-backup-") && strings.HasSuffix(e.Name(), ".db") {
			defaultFound = true
		}
	}
	if !defaultFound {
		t.Fatal("default backup file not written to CWD")
	}

	// 显式输出:路径含单引号(Windows/Unix 文件名均合法)。
	quoted := filepath.Join(tmp, "backup 'quoted'.db")
	if err := runBackup(db, quoted); err != nil {
		t.Fatalf("backup with quote in path: %v", err)
	}
	if _, err := os.Stat(quoted); err != nil {
		t.Fatalf("quoted backup file missing: %v", err)
	}
}
