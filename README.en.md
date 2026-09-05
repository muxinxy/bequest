# Bequest (托孤)

A digital asset vault + digital will. Manage physical/virtual assets; when the owner stops logging in, escalation reminders fire and encrypted keys are eventually handed over to designated inheritors.

> 中文版见 [README.md](README.md) · English version below.

## Layout

- `app/` — Flutter client (Android + Web from one codebase)
- `server/` — Go backend (HTTP API + reminder scheduler + inheritance handover)
- `docs/` — architecture (ADRs) and development progress (handover notes)

## Features

- **Web client**: same Flutter code compiled to Web and served same-origin by the Go server (`go run .` auto-detects and serves `app/build/web`); open `http://localhost:8080`. Argon2 uses a self-hosted hash-wasm WASM (`app/web/assets/hash-wasm.js`) for ~0.3s derivation; relative URLs by default (no CORS), plus a CORS middleware for standalone deployment / Flutter dev server.
- **Asset management**: physical/virtual assets, preset + custom categories, end-to-end encrypted sensitive fields (AES-256-GCM, per-asset key AK wrapped by master/inheritance keys; legacy assets auto-fall back to the master key). Grouped home view (collapsible by category), search matches category and asset names.
- **Inheritance (dead man's switch)**: inactivity escalation reminders (free 30/60/90/120 days; member 7/14/30/60 days) → trigger handover → inheritor claims the key with event_key + access code (two factors). Three cancellation windows (login before trigger / before claim / login reversal after claim). **Asset-level + category-level inheritance**: bind multiple inheritors per asset/category with per-binding trigger days; events fire per asset; an inheritor only receives the designated asset key. **Global inheritance toggle** in Settings.
- **Reminders**: per-asset expiry reminders (30/7/1 days + already-expired), default/custom templates, in-app inbox + email (SMTP).
- **Import/export**: JSON (all/category/single, master-password verified); encrypted `.beq` export; import with optional overwrite. Self-hosted sync: WebDAV/S3 encrypted backups (no login required, config stays on device).
- **Master password**: change (non-destructive re-wrap) and reset (account-password verified; old credentials unrecoverable after reset); **cross-device recovery** — new device re-derives via master password + salt.
- **Account**: change username/email and login password (all devices forced to re-login); login by username or email; real-time username/email availability checks (anti-enumeration); email-code password reset; dual password entry + master-password hint on signup.
- **Security**: app lock (PIN + biometrics incl. web), manual lock, free/member tiers (free asset cap 50), arithmetic captcha on register/login, per-IP rate limiting, admin 2FA (TOTP).
- **Claim page**: an inheritor opens `http://server/claim` to claim the key via event_key + access code; the owner can log in to reverse within 72h.
- **Local mode**: multiple local accounts (each with its own master password and encrypted data), cloud/local keys isolated.
- **Categories**: custom ordering, delete protection (move/merge), batch tidy, 30-day expiry warnings.

## Databases

The backend supports **SQLite (default)**, **MySQL 8 / MariaDB** and **PostgreSQL**. Select the backend with `DB_DRIVER` and configure via `DB_DSN` or `DB_HOST/DB_PORT/DB_USER/DB_PASS/DB_NAME`. Migrations are per-dialect and applied automatically at startup (embedded in the binary). See `server/README-deploy.md` for details and connection strings.

## Running

```bash
# Server (Go 1.26+)
cd server && go run .            # listens on :8080; first run creates server/data/bequest.db

# Or run against PostgreSQL/MySQL:
cd server
DB_DRIVER=postgres DB_USER=bequest DB_PASS=secret DB_NAME=bequest go run .

# Client (Flutter, Android/Web)
cd app && flutter run            # emulator reaches backend via http://10.0.2.2:8080

# Web client (served same-origin)
cd app && flutter build web
cd ../server && go run .         # open http://localhost:8080
```

## Admin console

Open `http://localhost:8080/admin` (embedded single page, served by Go, no build step). The page is bilingual (中文/English toggle).

- **First admin**: create/promote via env at startup
  `ADMIN_USERNAME=admin ADMIN_PASSWORD=<strong-password> go run .`
- **2FA**: admins can enable TOTP (Google Authenticator/Authy) from the config tab.
- **Features**: dashboard stats, user management (search, membership grant, admin appointment, disable/enable, delete, asset detail), system config (SMTP/SMS/phone providers + free asset cap, hot-reloaded via `config.json`), full audit log (CSV export).

## Deployment

### Docker Compose (recommended)

```bash
cd server
# create .env first (required):
#   JWT_SECRET=<long random string>
#   ENCRYPTION_KEY=<32-byte key used to encrypt SMTP passwords; dev default exists, production must set>
docker compose up -d --build
```

- Listens on `:8080`; data lives in `server/data/` (container `/data` volume).
- Multi-provider load balancing: mount `config.json` to `/data/config.json`.

### Binary

```bash
# Windows (PowerShell)
.\scripts\build.ps1

# Linux/macOS (cross-compiles 5 platforms)
VERSION=1.0.0 ./scripts/build.sh
```

### Environment variables

| Variable | Description |
|---|---|
| `DB_DRIVER` | `sqlite` (default), `mysql`, or `postgres` |
| `DB_DSN` | Optional full DSN (overrides the `DB_*` vars) |
| `DB_HOST/DB_PORT/DB_USER/DB_PASS/DB_NAME` | Connection details for MySQL/PostgreSQL |
| `JWT_SECRET` | JWT signing secret (required in production) |
| `ENCRYPTION_KEY` | AES key for SMTP password encryption (production required) |
| `SMTP_HOST/PORT/USER/PASS/FROM` | System mail (single server; multi-server via `config.json`) |
| `ADMIN_USERNAME/ADMIN_PASSWORD` | Bootstrap first admin |

Deployment details: [`server/README-deploy.md`](server/README-deploy.md).

## Releases (GitHub Actions)

Tagging `vX.Y.Z` builds binaries + Docker images and publishes to GitHub Releases (see `.github/workflows/release.yml`): 5-platform server binaries, Android APKs (release-signed, upgrade-safe), multi-arch GHCR images (`ghcr.io/muxinxy/bequest`).

## Design highlights

- End-to-end encryption: the master password derives an AES-256 key; sensitive data is encrypted client-side, the server never sees plaintext.
- Per-asset key isolation: each asset has its own AK; inheritors only receive the designated asset's wrapped key.
- Three cancellation windows: before trigger / before claim / owner-login reversal.
- Privacy first: self-hosted sync credentials stay on-device; reminder mail can use the user's own SMTP.

Architecture and progress: [`docs/`](docs/progress.md).
