package main

import "testing"

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
