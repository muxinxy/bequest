package main

import (
	"database/sql"
	"log"
	"net/http"
)

func main() {
	db, err := openDB()
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer db.Close()

	if err := runMigrations(db); err != nil {
		log.Fatalf("migrate: %v", err)
	}

	log.Println("bequest server listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", newMux(db)))
}

func newMux(db *sql.DB) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("POST /api/v1/auth/register", handleRegister(db))
	mux.HandleFunc("POST /api/v1/auth/login", handleLogin(db))
	mux.Handle("GET /api/v1/me", requireAuth(handleMe(db)))
	return mux
}
