package main

// TestPGXRWSmoke exercises the pgxrw driver wrapper against a real
// PostgreSQL only when TEST_PG_DSN is set; otherwise it is skipped so the
// default `go test` stays offline. Run:
//
//	TEST_PG_DSN="host=127.0.0.1 port=5433 user=bequest password=bequest dbname=bequest_test sslmode=disable" go test -run TestPGXRWSmoke
import (
	"database/sql"
	"os"
	"testing"
)

func TestPGXRWSmoke(t *testing.T) {
	dsn := os.Getenv("TEST_PG_DSN")
	if dsn == "" {
		t.Skip("TEST_PG_DSN not set; skipping live PostgreSQL smoke test")
	}
	old := currentDialect
	currentDialect = dialectPostgres
	defer func() { currentDialect = old }()

	db, err := sql.Open("pgxrw", dsn)
	if err != nil {
		t.Fatalf("open pg db: %v", err)
	}
	defer db.Close()

	if _, err := db.Exec(`DROP TABLE IF EXISTS smoke_t`); err != nil {
		t.Fatalf("drop: %v", err)
	}
	if _, err := db.Exec(`CREATE TABLE smoke_t (id BIGSERIAL PRIMARY KEY, name TEXT, n BIGINT)`); err != nil {
		t.Fatalf("create: %v", err)
	}
	res, err := db.Exec(`INSERT INTO smoke_t (name, n) VALUES (?, ?)`, "hello", int64(42))
	if err != nil {
		t.Fatalf("insert '?' placeholder failed (rewriter broken): %v", err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		t.Fatalf("rows affected = %d, want 1", n)
	}
	var name string
	var n int64
	if err := db.QueryRow(`SELECT name, n FROM smoke_t WHERE id = ?`, 1).Scan(&name, &n); err != nil {
		t.Fatalf("query '?' failed: %v", err)
	}
	if name != "hello" || n != 42 {
		t.Fatalf("got %q/%d, want hello/42", name, n)
	}
	// multi-statement Exec (used by migrations when not split)
	if _, err := db.Exec(`DROP TABLE IF EXISTS smoke_u; CREATE TABLE smoke_u (id BIGSERIAL PRIMARY KEY)`); err != nil {
		t.Fatalf("multi-statement exec failed: %v", err)
	}
	t.Log("pgxrw smoke OK")
}
