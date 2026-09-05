# Bequest (托孤) server

> 中文版: [README.md](README.md)

Go backend for the digital asset vault + digital will: HTTP API, reminder scheduling, inheritance handover, admin console. Ships as a single binary; SQLite / MySQL / PostgreSQL are selectable; UI and error messages are bilingual (中文/English).

> Deployment-focused guide: [README-deploy.en.md](README-deploy.en.md) · repo overview: [../README.en.md](../README.en.md)

## Quick start

```bash
# Local development (default SQLite, listens on :8080; first run auto-creates data/bequest.db)
go run .

# Specify a database (see "Databases" below)
DB_DRIVER=postgres DB_USER=bequest DB_PASS=secret DB_NAME=bequest go run .

# Browser entry points
#   http://localhost:8080        Flutter Web client (run cd ../app && flutter build web first)
#   http://localhost:8080/admin  Admin console
#   http://localhost:8080/claim  Inheritor claim page (no login required)
```

## Databases

`DB_DRIVER` selects the backend, default `sqlite`; migration scripts are embedded in the binary per dialect and executed automatically at startup (tracked in `schema_migrations`).

| Variable | Default | Description |
|---|---|---|
| `DB_DRIVER` | `sqlite` | `sqlite` / `mysql` / `postgres` |
| `DB_DSN` | empty | Full connection string; when set, the `DB_*` variables below are ignored |
| `DB_HOST` / `DB_PORT` | `127.0.0.1` / `3306` (mysql) `5432` (pg) | Address |
| `DB_USER` / `DB_PASS` | `bequest` / empty | Account |
| `DB_NAME` | `bequest` | Database name |

> The `backup` subcommand (`bequest-server backup`) is SQLite-only (VACUUM INTO); use `mysqldump` / `pg_dump` for MySQL/PostgreSQL.

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `JWT_SECRET` | **Required in production** | JWT signing key (HS256). Falls back to a dev key if unset, which allows token forgery |
| `ENCRYPTION_KEY` | **Required in production** | AES key that encrypts sensitive config such as SMTP passwords |
| `SMTP_HOST/PORT/USER/PASS/FROM` | No | System-mail fallback (takes effect only when no `config.json` exists) |
| `ADMIN_USERNAME/ADMIN_PASSWORD` | No | Bootstrap/promote the first admin at startup |
| `PORT` | `8080` | Listen port |
| `WEB_DIR` | Auto-detected | Flutter Web static directory (`WEB_DIR` > `./web` > `app/build/web`) |
| `DATA_DIR` | `data` | Data directory |

## Mail configuration (three layers, highest priority first)

1. **Admin console → system settings**: after editing, writes to `config.json` in the working directory and hot-reloads (recommended; covers SMTP/SMS/quota/tiers).
2. `SMTP_*` environment variables: single-server fallback only when no `config.json` exists.
3. User-level SMTP (App settings → mail sending settings): stored in the database; reminder mail prefers it, falling back to the system channel on failure.

## Common operations

```bash
# Start
go run .  # or ./bequest-server

# Health check (checks DB reachability)
curl http://localhost:8080/healthz

# Backup (SQLite)
./bequest-server backup     # produces bequest-backup-<timestamp>.db

# Version
curl http://localhost:8080/api/v1/version
```

## Deployment

- Docker Compose (recommended): see [docker-compose.yml](docker-compose.yml); create `.env` first (`JWT_SECRET`/`ENCRYPTION_KEY` required). For production, pull and run the image remotely using a compose file **without the `build:` section** or `docker run` (see the deployment section in the repo-root README).
- Binary cross-compilation: `../scripts/build.sh` (5 platforms) or `../scripts/build.ps1` (Windows).
- Detailed deployment guide: [README-deploy.en.md](README-deploy.en.md) (中文: [README-deploy.md](README-deploy.md)).
