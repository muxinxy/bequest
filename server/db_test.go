package main

import "testing"

func TestEmbeddedMigrationsAreAvailable(t *testing.T) {
	entries, err := migrationFS.ReadDir("migrations")
	if err != nil {
		t.Fatalf("read embedded migrations: %v", err)
	}
	if len(entries) == 0 {
		t.Fatal("embedded migrations are empty")
	}
}
