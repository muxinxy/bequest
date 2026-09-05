package main

import "database/sql"

// sqlExecer is satisfied by both *sql.DB and *sql.Tx, so execInsert works on
// standalone inserts and on statements inside a transaction.
type sqlExecer interface {
	Exec(query string, args ...any) (sql.Result, error)
	QueryRow(query string, args ...any) *sql.Row
}

// execInsert runs an INSERT and returns the new row's id across dialects.
// PostgreSQL has no LastInsertId, so on postgres the query must end with
// RETURNING id and be run via QueryRow. Callers pass the plain INSERT SQL
// (with '?'); the helper appends " RETURNING id" when currentDialect ==
// dialectPostgres and runs QueryRow(...).Scan(&id); on sqlite/mysql it runs
// Exec and reads LastInsertId.
func execInsert(db sqlExecer, query string, args ...any) (int64, error) {
	if currentDialect == dialectPostgres {
		var id int64
		err := db.QueryRow(query+" RETURNING id", args...).Scan(&id)
		return id, err
	}
	res, err := db.Exec(query, args...)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}
