package main

import (
	"database/sql"
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	// sqlite driver (pure Go). The MySQL and PostgreSQL drivers are wired in
	// mysql.go / pgx.go; importing them here keeps one openDB entry point.
	_ "github.com/go-sql-driver/mysql"
	_ "modernc.org/sqlite"
)

//go:embed migrations/sqlite/*.sql
var sqliteMigrationFS embed.FS

//go:embed migrations/mysql/*.sql
var mysqlMigrationFS embed.FS

//go:embed migrations/postgres/*.sql
var postgresMigrationFS embed.FS

// dialect selects the SQL flavor. Every SQL string in this codebase is
// written for SQLite and adapted at runtime for MySQL/PostgreSQL via the
// helpers below (dbNow, dbNowAdd, ...) plus a driver-level '?'->'$N' rewrite
// on PostgreSQL (see pgx.go). Migrations live in per-dialect directories.
type dialect int

const (
	dialectSQLite dialect = iota
	dialectMySQL
	dialectPostgres
)

const dataDir = "data"

func (d dialect) String() string {
	switch d {
	case dialectSQLite:
		return "sqlite"
	case dialectMySQL:
		return "mysql"
	case dialectPostgres:
		return "postgres"
	}
	return "unknown"
}

// currentDialect is set once at process start by openDB (and by test
// helpers before opening a test DB). Handlers read it after setup only.
var currentDialect = dialectSQLite

func sqlDialect() dialect { return currentDialect }

// ---------------------------------------------------------------------------
// SQL expression helpers. These embed the right function call / literal for
// the active dialect directly into SQL strings, so the app-level queries can
// stay written in one portable style. All timestamps are stored as UTC text
// "2006-01-02 15:04:05" (and dates as "2006-01-02"), so string comparisons
// behave identically on every backend.
// ---------------------------------------------------------------------------

// dbNow returns a SQL expression for the current UTC time as text.
func dbNow() string {
	switch currentDialect {
	case dialectMySQL:
		return "DATE_FORMAT(UTC_TIMESTAMP(), '%Y-%m-%d %H:%i:%s')"
	case dialectPostgres:
		return "to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS')"
	default:
		return "datetime('now')"
	}
}

// dbNowAdd returns a SQL expression for now ± offset, where offset uses the
// SQLite phrasing ("5 minutes", "72 hours", "-1 hour", "-90 days", ...).
func dbNowAdd(offset string) string {
	switch currentDialect {
	case dialectMySQL:
		return fmt.Sprintf("DATE_FORMAT(DATE_ADD(UTC_TIMESTAMP(), INTERVAL %s), '%%Y-%%m-%%d %%H:%%i:%%s')", intervalSQL(offset))
	case dialectPostgres:
		return fmt.Sprintf("to_char((now() at time zone 'utc') + interval '%s', 'YYYY-MM-DD HH24:MI:SS')", offset)
	default:
		return fmt.Sprintf("datetime('now', '%s')", offset)
	}
}

// intervalSQL rewrites SQLite's "<n> minutes|hours|days" offset phrasing into
// MySQL's "<n> MINUTE|HOUR|DAY" INTERVAL operand.
func intervalSQL(offset string) string {
	parts := strings.SplitN(offset, " ", 2)
	if len(parts) != 2 {
		return offset
	}
	unit := parts[1]
	if strings.HasSuffix(unit, "s") {
		unit = strings.TrimSuffix(unit, "s")
	}
	return parts[0] + " " + unit
}

// dbDateAddDays returns a SQL expression: value (a column or bind param,
// text in the app timestamp/date format) shifted by n days.
func dbDateAddDays(value string, n int) string {
	switch currentDialect {
	case dialectMySQL:
		return fmt.Sprintf("DATE_FORMAT(DATE_ADD(STR_TO_DATE(%s, '%%Y-%%m-%%d %%H:%%i:%%s'), INTERVAL %d DAY), '%%Y-%%m-%%d %%H:%%i:%%s')", value, n)
	case dialectPostgres:
		return fmt.Sprintf("to_char((%s)::timestamp + interval '%d days', 'YYYY-MM-DD HH24:MI:SS')", value, n)
	default:
		return fmt.Sprintf("datetime(%s, '%+d days')", value, n)
	}
}

// dbDateOneDayLater returns a SQL expression: the date one day after value,
// where value is a date-only string "YYYY-MM-DD".
func dbDateOneDayLater(value string) string {
	switch currentDialect {
	case dialectMySQL:
		return fmt.Sprintf("DATE_FORMAT(DATE_ADD(STR_TO_DATE(%s, '%%Y-%%m-%%d'), INTERVAL 1 DAY), '%%Y-%%m-%%d')", value)
	case dialectPostgres:
		return fmt.Sprintf("to_char((%s)::timestamp + interval '1 day', 'YYYY-MM-DD')", value)
	default:
		return fmt.Sprintf("date(%s, '+1 day')", value)
	}
}

// dbMonth returns a SQL expression yielding the "YYYY-MM" prefix of a text
// timestamp column.
func dbMonth(col string) string {
	switch currentDialect {
	case dialectPostgres:
		return fmt.Sprintf("substring(%s from 1 for 7)", col)
	default:
		return fmt.Sprintf("substr(%s, 1, 7)", col)
	}
}

// dbGroupConcat returns SQL for concatenating expr values with separator sep
// (GROUP_CONCAT on SQLite/MySQL, string_agg on PostgreSQL).
func dbGroupConcat(expr, sep string) string {
	switch currentDialect {
	case dialectPostgres:
		return fmt.Sprintf("string_agg(%s, '%s')", expr, sep)
	case dialectMySQL:
		return fmt.Sprintf("GROUP_CONCAT(%s SEPARATOR '%s')", expr, sep)
	default:
		return fmt.Sprintf("GROUP_CONCAT(%s, '%s')", expr, sep)
	}
}

// uniqueViolation reports whether err is a unique-constraint violation on the
// active dialect. isUniqueViolation is kept as an alias for call sites that
// used the old name.
func uniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	switch currentDialect {
	case dialectMySQL:
		return strings.Contains(msg, "Error 1062") || strings.Contains(msg, "Duplicate entry")
	case dialectPostgres:
		return strings.Contains(msg, "duplicate key") || strings.Contains(msg, "SQLSTATE 23505")
	default:
		return strings.Contains(msg, "UNIQUE constraint failed")
	}
}

// envOr returns env[key] or def when unset/empty.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// smtpUserCol returns the dialect-correct reference to the `user` column of
// user_smtp. PostgreSQL reserves the bare keyword `user`, so it must be
// quoted there; SQLite and MySQL accept it unquoted (MySQL via backticks is
// also fine but unnecessary since MariaDB/MySQL 8 permit bare `user`).
func smtpUserCol() string {
	if currentDialect == dialectPostgres {
		return `"user"`
	}
	return "user"
}

// openDB opens the configured database. DB_DRIVER selects the backend:
//   - "sqlite" (default): data/bequest.db, WAL mode + busy timeout
//   - "mysql":  DB_DSN, or DB_HOST/DB_PORT/DB_USER/DB_PASS/DB_NAME
//   - "postgres": DB_DSN, or DB_HOST/DB_PORT/DB_USER/DB_PASS/DB_NAME
func openDB() (*sql.DB, error) {
	driver := os.Getenv("DB_DRIVER")
	switch driver {
	case "":
		driver = "sqlite"
	case "sqlite", "mysql", "postgres", "postgresql":
	default:
		return nil, fmt.Errorf("unsupported DB_DRIVER %q (want sqlite|mysql|postgres)", driver)
	}
	switch driver {
	case "mysql":
		currentDialect = dialectMySQL
	case "postgres", "postgresql":
		currentDialect = dialectPostgres
	default:
		currentDialect = dialectSQLite
	}

	switch currentDialect {
	case dialectMySQL:
		dsn := os.Getenv("DB_DSN")
		if dsn == "" {
			user := envOr("DB_USER", "bequest")
			pass := os.Getenv("DB_PASS")
			host := envOr("DB_HOST", "127.0.0.1")
			port := envOr("DB_PORT", "3306")
			name := envOr("DB_NAME", "bequest")
			dsn = fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?charset=utf8mb4&collation=utf8mb4_unicode_ci&parseTime=false&loc=UTC&clientFoundRows=true",
				user, pass, host, port, name)
		}
		db, err := sql.Open("mysql", dsn)
		if err != nil {
			return nil, fmt.Errorf("open mysql db: %w", err)
		}
		db.SetMaxOpenConns(25)
		db.SetMaxIdleConns(5)
		return db, nil
	case dialectPostgres:
		dsn := os.Getenv("DB_DSN")
		if dsn == "" {
			host := envOr("DB_HOST", "127.0.0.1")
			port := envOr("DB_PORT", "5432")
			user := envOr("DB_USER", "bequest")
			pass := os.Getenv("DB_PASS")
			name := envOr("DB_NAME", "bequest")
			dsn = fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
				host, port, user, pass, name)
		}
		// pgxrw is the pgx stdlib driver wrapped with a '?'->'$N' rewriter.
		db, err := sql.Open("pgxrw", dsn)
		if err != nil {
			return nil, fmt.Errorf("open postgres db: %w", err)
		}
		db.SetMaxOpenConns(25)
		db.SetMaxIdleConns(5)
		return db, nil
	default:
		if err := os.MkdirAll(dataDir, 0o755); err != nil {
			return nil, fmt.Errorf("create data dir: %w", err)
		}
		dsn := "file:" + filepath.Join(dataDir, "bequest.db") +
			"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)"
		db, err := sql.Open("sqlite", dsn)
		if err != nil {
			return nil, fmt.Errorf("open db: %w", err)
		}
		// modernc sqlite is a single connection by default for writes; cap pool to avoid contention
		db.SetMaxOpenConns(1)
		return db, nil
	}
}

// migrationsFS returns the embedded migration set for the active dialect,
// rooted at the dialect directory itself. The embed directives below include
// the migrations/<dialect>/ path prefix, so the returned FS is the "migrations"
// tree; we Sub into the dialect folder so ReadDir(".") lists the *.sql files.
func migrationsFS() fs.FS {
	var base embed.FS
	switch currentDialect {
	case dialectMySQL:
		base = mysqlMigrationFS
	case dialectPostgres:
		base = postgresMigrationFS
	default:
		base = sqliteMigrationFS
	}
	sub, err := fs.Sub(base, "migrations/"+currentDialect.String())
	if err != nil {
		// Cannot happen: the embed patterns pin these directories.
		panic("migrations embed dir missing: " + err.Error())
	}
	return sub
}

// splitStatements splits a migration file body into individual statements.
// Migration files are DDL/DML only (no triggers/procedures with embedded
// semicolons) and each statement ends with ';' at end of line, so this is
// safe. Comments ('--') are dropped.
func splitStatements(body string) []string {
	var out []string
	var cur strings.Builder
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "--") {
			continue
		}
		cur.WriteString(line)
		cur.WriteString("\n")
		if strings.HasSuffix(trimmed, ";") {
			out = append(out, cur.String())
			cur.Reset()
		}
	}
	return out
}

// runMigrations applies every migration in the active dialect's embedded
// directory that is not yet recorded in schema_migrations, in filename
// order. SQLite and PostgreSQL migrations are wrapped in a transaction per
// file (both support transactional DDL). MySQL DDL auto-commits, so MySQL
// migrations run statement by statement without a wrapping transaction.
func runMigrations(db *sql.DB) error {
	var createTable string
	switch currentDialect {
	case dialectMySQL:
		createTable = `CREATE TABLE IF NOT EXISTS schema_migrations (
			version    VARCHAR(255) PRIMARY KEY,
			applied_at VARCHAR(19) NOT NULL
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`
	case dialectPostgres:
		createTable = `CREATE TABLE IF NOT EXISTS schema_migrations (
			version    TEXT PRIMARY KEY,
			applied_at TEXT NOT NULL
		)`
	default:
		createTable = `CREATE TABLE IF NOT EXISTS schema_migrations (
			version    TEXT PRIMARY KEY,
			applied_at TEXT NOT NULL DEFAULT (datetime('now'))
		)`
	}
	if _, err := db.Exec(createTable); err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}

	mfs := migrationsFS()
	entries, err := fs.ReadDir(mfs, ".")
	if err != nil {
		return fmt.Errorf("read migrations dir: %w", err)
	}
	applied := map[string]bool{}
	rows, err := db.Query(`SELECT version FROM schema_migrations`)
	if err != nil {
		return fmt.Errorf("query schema_migrations: %w", err)
	}
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			rows.Close()
			return err
		}
		applied[v] = true
	}
	rows.Close()

	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)

	for _, f := range files {
		if applied[f] {
			continue
		}
		body, err := fs.ReadFile(mfs, f)
		if err != nil {
			return fmt.Errorf("read migration %s: %w", f, err)
		}
		statements := splitStatements(string(body))
		if len(statements) == 0 {
			return fmt.Errorf("migration %s: no statements", f)
		}
		if err := applyMigration(db, f, statements); err != nil {
			return err
		}
	}
	return nil
}

// applyMigration runs a migration file's statements and records it in
// schema_migrations. Record happens only after every statement succeeds;
// a later retry re-runs the whole file (idempotency across a partial MySQL
// failure is not guaranteed because MySQL DDL cannot roll back).
func applyMigration(db *sql.DB, name string, statements []string) error {
	record := func(tx *sql.Tx) error {
		var insertSQL string
		if currentDialect == dialectPostgres {
			insertSQL = `INSERT INTO schema_migrations (version, applied_at) VALUES ($1, $2)`
		} else {
			insertSQL = `INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)`
		}
		_, err := tx.Exec(insertSQL, name, time.Now().UTC().Format("2006-01-02 15:04:05"))
		return err
	}

	if currentDialect == dialectMySQL {
		// MySQL DDL auto-commits; run each statement directly.
		for _, stmt := range statements {
			if _, err := db.Exec(stmt); err != nil {
				return fmt.Errorf("apply migration %s: %w", name, err)
			}
		}
		tx, err := db.Begin()
		if err != nil {
			return fmt.Errorf("begin record %s: %w", name, err)
		}
		if err := record(tx); err != nil {
			tx.Rollback()
			return fmt.Errorf("record migration %s: %w", name, err)
		}
		return tx.Commit()
	}

	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("begin migration %s: %w", name, err)
	}
	for _, stmt := range statements {
		if _, err := tx.Exec(stmt); err != nil {
			tx.Rollback()
			return fmt.Errorf("apply migration %s: %w", name, err)
		}
	}
	if err := record(tx); err != nil {
		tx.Rollback()
		return fmt.Errorf("record migration %s: %w", name, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit migration %s: %w", name, err)
	}
	return nil
}
