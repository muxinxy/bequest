# Bequest (托孤) server deployment

> 中文版: [README-deploy.md](README-deploy.md)

> Repo: https://github.com/muxinxy/bequest | Image: `ghcr.io/muxinxy/bequest`
> Server: Go 1.26, single binary, listens on 8080 by default, SQLite database `data/bequest.db` (created automatically at runtime).

---

## 1. Building the binary

The version string is injected at compile time via `-ldflags "-X main.version=<version>"`, and `GET /api/v1/version` returns that version.

### Windows (PowerShell)

```powershell
# Run from the repository root
.\scripts\build.ps1                 # version is dev
$env:VERSION = "1.0.0"
.\scripts\build.ps1                 # version is 1.0.0
```

- Builds `windows/amd64` and `linux/amd64` by default;
- Default `GOPROXY=https://goproxy.cn,direct` (for networks in mainland China); override with `$env:GOPROXY`;
- Outputs: `dist\bequest-server-<version>-windows-amd64.exe`, `dist\bequest-server-<version>-linux-amd64` (version defaults to `dev`; set it with `$env:VERSION`).

### Linux / macOS

```bash
# Run from the repository root
./scripts/build.sh                 # version is dev
VERSION=1.0.0 ./scripts/build.sh   # version is 1.0.0
GOPROXY=https://goproxy.cn,direct ./scripts/build.sh   # override the proxy for networks in mainland China
```

Cross-compiles 5 platforms: `linux/amd64`, `linux/arm64`, `windows/amd64` (with `.exe`), `darwin/amd64`, `darwin/arm64`; outputs land in `dist/` (filenames include the version, e.g. `bequest-server-1.0.0-linux-amd64`).

---

## 2. Running with Docker Compose

```bash
cd server
# Create .env (JWT_SECRET / ENCRYPTION_KEY required)
#   JWT_SECRET=replace with a long random string
#   ENCRYPTION_KEY=replace with a long random string
docker compose up -d --build
```

- The service listens on host port `8080`;
- Data lands in `server/data/` on the host (volume mount `./data:/data`);
- Inside the container `WORKDIR=/data`, and the database is written to `data/bequest.db` on the volume; the SQL migration files are already embedded in the server binary, so there is no need to mount the `migrations/` directory into the container;
- The same applies to `config.json`: the server reads `config.json` from its CWD, so simply mount the host config file into the container (uncomment the corresponding lines in `docker-compose.yml`):

```yaml
volumes:
  - ./data:/data
  - ./config.json:/data/config.json   # uncomment to enable
```

---

## 3. config.json (multi-SMTP example)

> Note: the current code still provides single-SMTP support via the `SMTP_*` environment variables; multiple SMTP servers are configured through `config.json`.

```json
{
  "smtp_servers": [
    {
      "host": "smtp.qq.com",
      "port": 465,
      "user": "noreply@qq.com",
      "password": "SMTP authorization code",
      "from_addr": "noreply@qq.com"
    },
    {
      "host": "smtp.163.com",
      "port": 465,
      "user": "noreply@163.com",
      "password": "SMTP authorization code",
      "from_addr": "noreply@163.com"
    }
  ]
}
```

> Ports: 465 is implicit TLS and 587 is STARTTLS; both are supported. Services like QQ/163 require obtaining an "authorization code" from the mailbox settings rather than using your login password.

Save the above as `server/config.json` (or mount it as `/data/config.json` as described above); the server automatically reads `config.json` from its CWD on startup.

---

## 4. Environment variables

| Variable | Required | Description |
|------|------|------|
| `JWT_SECRET` | Yes | JWT signing key; must be a high-strength random value in production |
| `ENCRYPTION_KEY` | Yes | Encryption key; must be a high-strength random value in production |
| `DB_DRIVER` | No | Database driver: `sqlite` (default) / `mysql` / `postgres` |
| `DB_DSN` | No | Full connection string; when set, the individual `DB_*` variables below are ignored |
| `DB_HOST` | No | MySQL/PostgreSQL host (default `127.0.0.1`) |
| `DB_PORT` | No | Port (MySQL default `3306`; Postgres default `5432`) |
| `DB_USER` | No | Database user (default `bequest`) |
| `DB_PASS` | No | Database password |
| `DB_NAME` | No | Database name (default `bequest`) |
| `SMTP_HOST` | No | SMTP server address (e.g. `smtp.qq.com`) |
| `SMTP_PORT` | No | SMTP port (e.g. 465/587) |
| `SMTP_USER` | No | SMTP username |
| `SMTP_PASS` | No | SMTP password/authorization code |
| `SMTP_FROM` | No | Sender address |
| `DATA_DIR` | No | Data directory (defaults to `/data` inside the image) |

### Using MySQL / PostgreSQL

The connection string can also be provided entirely via `DB_DSN`:

```bash
# PostgreSQL (libpq format)
DB_DRIVER=postgres \
DB_DSN="host=127.0.0.1 port=5432 user=bequest password=secret dbname=bequest sslmode=disable" \
go run .

# MySQL (Go driver format)
DB_DRIVER=mysql \
DB_DSN="bequest:secret@tcp(127.0.0.1:3306)/bequest?charset=utf8mb4&parseTime=false&clientFoundRows=true" \
go run .
```

- On first startup, migrations for the matching dialect run automatically against the target database (create tables/indexes/seed data), tracked in the `schema_migrations` table;
- The `backup` subcommand supports SQLite only (`VACUUM INTO`); use `mysqldump` / `pg_dump` for MySQL/PostgreSQL.

---

## 5. Release workflow

`.github/workflows/release.yml` triggers automatically when a **`v*` tag is pushed**, e.g.:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Once triggered, the following jobs run in sequence:

1. **build** — cross-compiles the 5-platform binaries on `ubuntu-latest` (the version is taken from the tag, `v` prefix stripped, injected via `-X main.version=1.0.0`); outputs are uploaded as workflow artifacts;
2. **docker** — `docker/build-push-action` builds the `linux/amd64` + `linux/arm64` multi-arch images and pushes them to `ghcr.io/muxinxy/bequest` with the `1.0.0` (semver) and `latest` tags;
3. **android** — builds release-signed APKs for 3 ABIs (filenames include the version, e.g. `bequest-v1.0.0-arm64-v8a.apk`);
4. **release** — `softprops/action-gh-release` attaches the binary and APK artifacts to a GitHub Release (draft: false, release notes auto-generated).

You can also trigger it manually from the workflow page (workflow_dispatch); in that case the version is `dev`, only the image is built and pushed, and no Release is created.

---

## 6. Android release signing (Secrets)

APKs are signed with a fixed release keystore (so version upgrades do not require uninstall/reinstall). CI restores the signing files from GitHub Secrets at build time; the repo does not store the keystore/passwords.

Configure 4 Secrets under the repository **Settings → Secrets and variables → Actions**: `ANDROID_KEYSTORE_BASE64` (base64 of the keystore file), `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`. For how to generate a keystore locally, see [`README.md`](../README.md#发布签名secrets) in the repo root (Chinese).
