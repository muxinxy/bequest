# Bequest (托孤) — Architecture & Design Decisions

> Handover companion. This document records stable architecture decisions; progress and status live in `docs/progress.md`. 中文原文见 [architecture.md](architecture.md).

## Product positioning

A digital asset vault + digital will: manage physical/virtual assets; when the owner stops logging in, escalation reminders fire at growing intervals; eventually the decryption keys are handed over to designated inheritors.

## Tech stack

| Layer | Choice | Notes |
|---|---|---|
| Client | Flutter 3.44 (Dart) | One codebase compiled to Android + Web (flutter_ohos planned later) |
| Local storage | SQLite (drift) + field-level AES-256-GCM | Sensitive fields ciphertext, non-sensitive fields plaintext |
| Key derivation | Argon2id → AES-256 master key | Master password ≠ account password; losing the master password = losing the data (deliberate) |
| Backend | Go (standard library `net/http`) | Single binary; 1.22+ routing patterns |
| Database | SQLite (`modernc.org/sqlite`, pure Go) | Starting point; migrate to PostgreSQL later |
| Auth | JWT (`golang-jwt`) | Account passwords hashed with argon2id |
| Push / mail | FCM + SMTP | These two channels suffice for the free tier |

## Directory structure

```
bequest/
├── app/                          # Flutter client (Android + Web)
│   └── lib/
│       ├── main.dart             # Entry: routing by login state
│       ├── api/                  # HTTP client
│       ├── crypto/               # Master-password derivation, encrypt/decrypt
│       ├── platform/             # Platform abstractions: string_store/file_share (io/web dual implementations)
│       ├── pages/                # Screens
│       └── widgets/
├── server/                       # Go backend
│   ├── main.go                   # Wiring: db, routes, startup
│   ├── db.go                     # SQLite open + migration execution
│   ├── auth.go                   # Register/login + JWT issuance
│   ├── middleware.go             # Auth middleware
│   └── migrations/001_init.sql   # Schema script (go:embed, auto-executed)
├── docs/
│   ├── architecture.md           # This document (Chinese original)
│   ├── architecture.en.md        # English version (this file)
│   └── progress.md               # Development progress
└── README.md
```

## Core design decisions (ADRs)

### ADR-1 End-to-end encryption (option A: keys issued at inheritance)

- Client derives master key MK (AES-256-GCM) from the master password via Argon2id
- Asset sensitive data (credentials/notes) is encrypted with MK and uploaded — the **server never sees plaintext**
- At registration the client generates a random "inheritance wrapping key" WK and uploads `master_key_wrapped = encrypt(WK, MK)`
- When inheritance is triggered, the server issues `master_key_wrapped` to the inheritor, who recovers MK using WK
- WK is delivered to the inheritor by the owner beforehand (offline channel, e.g. in person / on paper)

### ADR-2 Inheritance state machine and the three cancellation windows

States: `inactive → warning → triggered → claimed → reversed`

1. Owner times out of login → reminders escalate (ladder: free 30/60/90/120 days, member 7/14/30/60 days; one in-app message per rung, email from L3 on) → owner logging in cancels (resets the ladder)
2. `triggered`: the scheduler creates `inheritance_events` (random 16-byte `event_key` + a hash snapshot of the inheritor's access code), advances stage→triggered, and emails the `event_key` to the inheritor via SMTP (recorded in the audit log when SMTP is unconfigured)
3. `claimed`: the inheritor claims with **event_key + preset access code (two factors)**, no account needed → receives `users.master_key_wrapped`; owner logging in reverses the event (`reversed`) — the third window; the server-side implementation of the 72h reconsideration period is "login reverses it", with no countdown-based auto-completion (the 72h countdown after handover is a future enhancement)

### ADR-3 Free/member differentiation

- Free quota: asset cap of 50 (403); members unlimited; the `assetCount` check runs at asset creation
- Reminder channels: free = in-app message + email (when SMTP is configured); member = in-app message + email + SMS/phone (`notifyUser` dispatch; SMS/phone are reserved no-op implementations — the users table has no phone field yet)
- Inheritance escalation ladders: free 30/60/90/120 days, member 7/14/30/60 days
- Perk gates: export format (free JSON, Excel deferred for members), custom templates (currently free for all; can be tightened later)
- Membership grants: an admin flips `tier` directly on the user-management page of the admin console (ADR-16); or `UPDATE users SET tier='member'`

### ADR-8 Self-hosted sync (privacy first, client connects directly)

- Users who are privacy-conscious can sync encrypted backups to their own WebDAV/S3 (FTP/SFTP reserved)
- Sync credentials are **stored on-device only** (secure_store) and never pass through the bequest server; sync actions connect client-direct to the remote
- A backup = full data dump (asset ciphertext + categories + templates + inheritors) packaged into a single file encrypted with the master key (AES-GCM)
- Hand-rolled on purpose: `webdav_client` internally uses dio (cannot inject an http.Client/MockClient for tests), `aws_s3` lacks null safety; SigV4 is implemented with `package:crypto` and locked down against AWS's official test vectors

### ADR-9 Custom sender and multi-channel load balancing

- Users can configure their own SMTP (migration 003 `user_smtp`); the scheduler's `notifyUser` prefers the user's SMTP and falls back to the system SMTP — addressing the privacy concern of "afraid of the vendor's mail service"
- SMTP passwords are stored AES-256-GCM encrypted (`ENCRYPTION_KEY` env; the dev default key is dev-only, production must set it)
- System multi-channel: optional `server/config.json` (`smtp_servers[]` round-robin + `sms_providers[]`/`phone_providers[]` reserved), falling back to env `SMTP_*` when absent; `sendMailSystem` round-robins trying each
- Version: `GET /api/v1/version`; Release builds inject the tag via `-X main.version=<tag>`

### ADR-11 Cloud/local dual-mode storage and entitlements

- **Storage abstraction**: `AssetRepository` (8 CRUD methods) — `CloudAssetRepository` (ApiClient, jwt) + `LocalAssetRepository` (LocalVault, an encrypted local library keyed by the master key); `RepositoryFactory.resolve(jwt, masterKeyB64)` selects by storage mode; every screen goes through the repository; the server address is configurable (`ApiConfig.baseUrl()`, saved/tested on the settings page)
- **No-login local mode**: "Enter local mode" on the login page → first-time master-password setup (salt-derived MK stored in secure_store + vault initialized) → full local CRUD; exiting local mode does not wipe on-device data
- **Cross-device recovery**: the sync payload carries the `salt` (plaintext, not sensitive); `extractBackupJsonAny` first tries the on-device MK, then re-derives with "master password + backup salt"; after recovery the on-device master key can be set
- **Three entitlement tiers**: guest (20 assets, no cloud sync/inheritance, local usable) / free (50 assets, cloud sync + inheritance) / member (unlimited); UI badges + asset-cap blocking at creation time
- **Mode switch**: cloud→local (pull everything, write to vault) / local→cloud (login required, upload item by item, categories deduped by name) — copy-style migration, not continuous sync (`ponytail:` upgradeable to bidirectional incremental later)
- **Releases**: Release includes Android APKs (`flutter build apk --release --split-per-abi`, three ABIs uploaded as assets)
- Android networking: main manifest gains the `INTERNET` permission + `usesCleartextTraffic` (required for self-hosted HTTP; debug/profile build permissions/config do not carry into release)

- Binaries: `scripts/build.sh` (5 platforms) / `build.ps1` (local Windows); Docker: multi-stage alpine, non-root, `WORKDIR=/data` so the relative path `data/bequest.db` lands on the volume
- Releases: tag `v*` triggers GitHub Actions — matrix builds + buildx dual-arch push to `ghcr.io/muxinxy/bequest` + Release assets; the workflow quotes `"on":` to dodge YAML 1.1 boolean coercion
- Migrations in deployment: SQL migrations are compiled into the binary via `go:embed`, so the Docker runtime needs no external `migrations/` directory; only `/data` is persisted as the database volume

### ADR-12 Asset-level key isolation

- Each asset gets an independent random AK (AES-256); asset ciphertext is encrypted with AK; AK is wrapped for the owner (MK) and for inheritors (WK) and uploaded as `asset_key_wrapped_mk` / `asset_key_wrapped_wk` (two new columns on `assets`, migration 005)
- New `asset_inheritors` table: `asset_id × inheritor_id × priority × trigger_days` (`UNIQUE(asset_id, inheritor_id)`); a binding enables asset-level inheritance, with `trigger_days` judged independently, otherwise the global escalation ladder applies
- `inheritance_events` gains an `asset_id` column (NULL = whole-vault event); the scheduler's `triggerInheritance` first creates per-asset events from `asset_inheritors`; if every asset is bound, the whole-vault event is skipped
- Inheritor claim: asset-level events return `{"asset_key_wrapped_wk","asset_id","status"}` — the inheritor receives only the designated asset's key, never `master_key_wrapped`
- Gradual compatibility for legacy assets: the client's `decryptAssetData` unwraps AK and decrypts when `asset_key_wrapped_mk` is present, otherwise falls back to decrypting straight with MK (historical data unaffected)
- Management: three handlers in `server/asset_inheritors.go` (list/create/delete), validating that the inheritor belongs to the same user; API `GET/POST /api/v1/assets/{id}/inheritors`, `DELETE /api/v1/assets/{id}/inheritors/{iid}`
- Category-level inheritance (migration 007 `category_inheritors`: `category_id × inheritor_id × priority × trigger_days`, `UNIQUE(category_id, inheritor_id)`): a category binding is the default inheritor for that category's assets that have no asset-level binding; asset-level bindings take precedence
- Scheduler `triggerInheritance`: assets without asset-level bindings are handed over via their category's `category_inheritors` (JOIN inheritors/assets, `NOT EXISTS` filtering out asset-level-bound assets); category-bound assets likewise get one event per asset and count into boundAssets; assets with asset-level/category-level config never enter the whole-vault event
- The "inheritor's bound assets" list returns **binding entities** (one row per category + one row per asset, no longer expanding categories into per-asset rows): category rows carry `asset_count` (assets inherited through that category, excluding asset-level-bound ones); empty categories stay visible and can be unbound

### ADR-13 Web client

- The same Flutter code compiles to Web; the server statically hosts `build/web` with SPA fallback (`webDir()` in `web.go`: `WEB_DIR` env > auto-detect; `spaHandler` serves real files directly, returns 404 for `/api/*`, and falls back to `index.html` otherwise)
- CORS middleware: `Allow-Origin *` (Bearer auth has no cookies, so `*` is acceptable), `OPTIONS` preflight → 204
- Web-side argon2id derivation: self-hosted WASM (`web/assets/hash-wasm.js`, ~0.3s vs ~33s pure JS); conditional import of `key_derivation_io.dart` (pointycastle) / `key_derivation_web.dart` (hash-wasm)
- Platform storage abstractions: `string_store` (file / localStorage), `file_share` (system share / browser download) — io and web implementations under `platform/`
- `local_auth` disabled on Web (no biometrics in the browser); Web defaults to relative-path requests (same-origin, no CORS)
- Web lock fix: AppLockScreen's auto-release condition now includes `!_hasMasterKey` (the master password is also a verifiable unlock method, so users who set only a master password must not be auto-released); `LockGate.lockNow` locks unconditionally and the lock screen itself handles the no-credentials case (auto-release only when no unlock method exists) — fixes the root cause of manual lock failing immediately on web

### ADR-14 Inheritance toggle (global)

- Migration 006: `users.inheritance_enabled` (default 1); when off, the scheduler skips escalation reminders and inheritance triggering
- API: `GET /api/v1/settings/inheritance` (reads `{"enabled":bool}`), `PUT /api/v1/settings/inheritance` (writes the switch)
- Scheduler `processEscalation` query gains `AND inheritance_enabled = 1`; the client has a SwitchListTile on the settings page (settings_page.dart)

### ADR-15 Master password reset

- Reuses `PUT /api/v1/settings/master-key` (account-password verification + swap of `master_key_wrapped`; zero new backend endpoints)
- Client `reset_master_password.dart`: derive new MK/new WK/new salt → update the cloud `master_key_wrapped` → per cloud asset keep metadata (name/category/expiry), wipe credentials, re-encrypt with a new AK → rebuild an empty local vault → update on-device keys
- Inherent cost of end-to-end encryption: old credentials are unrecoverable (the page tells the user this explicitly)

### ADR-16 Admin console

- Migration 009: `users.role` ('user'/'admin', default user) + `users.disabled` (disable flag)
- **Admin bootstrap**: `ADMIN_USERNAME`/`ADMIN_PASSWORD` env; `ensureAdmin` at startup — creates the account if the username doesn't exist (email `user@admin.local`), otherwise only promotes the role; never touches an existing user's password
- **Authorization**: `requireAdmin` (= requireAuth + live DB check of role/disabled — no stale-JWT-claim problem); the plain `requireAuth` also rejects disabled accounts (login endpoint 403, existing tokens 403)
- **Admin APIs** (prefix `/api/v1/admin`, all requireAdmin): `stats` (counts of users/members/assets/inheritors/pending-claim events, etc.), `users` list (q/role/tier filters + paging + asset/inheritor counts), `users/{id}` detail, `PUT users/{id}` (single-field updates of role/tier/disabled), `DELETE users/{id}` (cascades assets etc.; **self-protection**: cannot demote/disable/delete yourself), `audit-log` (full + `user_id` filter), `config` GET/PUT (system SMTP servers + `free_asset_quota`; passwords are never echoed, empty PUT fields keep the old value; writes `config.json` then `loadConfig()` hot-reloads)
- **Frontend**: single page embedded in `server/admin.html` (`//go:embed`, zero new dependencies, no build step), served same-origin at `GET /admin`; login reuses `POST /auth/login` plus the role check on `/me`; dashboard/users/config/audit tabs, vanilla JS + fetch
- Admin actions write audit log entries (actor='admin'); the `from_addr` in config.json depends on the `smtpServer` json tag fix (Go's case-folding field match doesn't cross underscores)
- Note: admins are also ordinary users (consume quota, can log into the app); deleting a user leaving orphan `reminders`/`inheritance_events` rows is not handled yet (filtered by `user_id`, no practical impact)

### ADR-17 Arithmetic captcha (register/login)

- **Choice**: an arithmetic captcha (`3 + 7 = ?`) — the simplest effective option: zero external dependencies, no image libraries or captcha services, and enough bot/brute-force protection (brute force is backstopped by ADR-18 rate limiting)
- `GET /api/v1/auth/captcha` generates a random 0-9 addition problem; the **answer is stored as a sha256 hash** in an in-memory cache (5-minute expiry)
- Login/register request bodies carry `captcha_id + captcha`; `verifyCaptcha` checks and **consumes once** (deletes the entry, preventing replay)
- Single-machine in-memory cache (`captcha.go` map + mutex); multi-instance deployments would need shared storage (this project is a single binary)
- Frontend: arithmetic card on the login/register pages (click to refresh); a wrong captcha auto-refreshes and retries

### ADR-18 Per-IP rate limiting

- In-memory sliding-window middleware (`rate_limit.go`): **login/register 5 requests/min/IP**, other APIs 120 requests/min/IP
- Over-limit returns 429 "too many requests"; windows auto-recover on expiry (`reset` clears stale entries to prevent memory growth)
- IP extraction: prefers `X-Forwarded-For` (reverse-proxy setups), otherwise `RemoteAddr`
- Wrapping order: `cors(rateLimit(newMux(db)))` — limiting runs before routing, so unauthenticated requests are throttled too (blocks unauthenticated endpoint hammering)
- Single-machine in-memory implementation; multi-instance would need shared storage (same as ADR-17)

### ADR-13 addendum — Web derivation fix

- **Root cause**: the web argon2 binding `js_util.callMethod(argon2id, 'call', [options])` compiles to `argon2id.call(options)`; JS `.call()` treats options as the **thisArg** rather than an argument, so hash-wasm receives empty parameters and throws `Invalid options parameter` — registration and local-mode master-password setup (both call `deriveMasterKey`) therefore failed
- **Fix**: `callMethod(hashwasm, 'argon2id', [options])` (= `hashwasm.argon2id(options)`); the derived result was verified byte-for-byte against the anchor value by loading the Dart-compiled artifact in Node
- Lesson: web-only binding logic needs real runtime verification (`dart compile js` + run in Node); passing `flutter build web` compilation alone is insufficient (dart2js does not validate runtime argument semantics)

### ADR-17 Cross-device key recovery

- Background: MK/salt/WK are only written to the local device at registration (ADR-1); after switching devices a login yields only a JWT — asset-detail decryption fails and saving lacks the WK
- Migration 010: `users.master_salt` (plaintext, not sensitive — same reasoning as ADR-11); uploaded at registration, returned at login
- Recovery (`crypto/recover_keys.dart`): master password + salt → re-derive MK (byte-identical to registration) → authenticate the master password via AES-GCM using any asset's `asset_key_wrapped_mk` → save MK/salt; when WK is missing: generate a new WK → verify the account password and update `master_key_wrapped` (reusing `PUT /settings/master-key`) → per asset re-wrap AK with the new WK (credential ciphertext kept as-is, non-destructive) → save the new WK. The owner must re-deliver the new WK offline
- Legacy-account backfill: `PUT /api/v1/settings/master-salt` — when the device has a salt but the server doesn't (registration predates this ADR), login uploads it automatically
- Trigger: the login page detects "no master key on device and the server has a salt" → shows a "recover encryption keys" dialog (master password + account password); cancel/failure → stays on the login page with credentials cleared

### ADR-18 Admin 2FA and inheritance security hardening

- **Claim rate limiting + auditing**: `/inheritance/claim` and `/auth/2fa/verify` share the login/register window (5/min/IP); failed claims are audited (unknown `event_key` → actor 'system', wrong access code → actor 'inheritor')
- **Admin login auditing**: full logins (including ones that pass 2FA) record `admin_login` (detail = source IP)
- **TOTP 2FA**: `users.totp_secret` (migration 011, base32); RFC 6238 via pure standard library (HMAC-SHA1, 30s, ±1 step); login is two-step: account password → `{totp_required, pending_token}` (a 5-minute pending token carrying the `pending_2fa` claim) → `POST /auth/2fa/verify` exchanges it for the real token; requireAuth/requireAdmin reject pending tokens (not usable as a session); enable flow is setup (returns the secret, not persisted) → confirm (persists after the code verifies) / disable (clears after the code verifies)
- **72h reconsideration window**: claim writes `reversable_until = claimed_at + 72h` (migration 011); the third window — owner login reversal — becomes "reversible inside the window, handover finalized after it expires"; the status endpoint returns `reversable_until`
- **Inheritor claim page**: `GET /claim` is an embedded single page (unauthenticated; claim validation happens in the API), so inheritors can claim keys without installing the app
- **Ops**: `/healthz` actually runs a `PingContext` DB check; the `bequest-server backup` subcommand takes a `VACUUM INTO` consistent snapshot; the `PORT` env overrides the listen port

### ADR-19 Multiple local accounts and key isolation

- Background: local mode was single-account (shared standard key slot + `vault.bq`); entering local mode would overwrite the cloud key slot, and re-entering auto-released without any verification
- **Account system** (SecureStore): `bequest_local_profiles`=[{id,name}]; each account's keys live in a dedicated slot `bequest_local_{mk,salt,wk,hint}_<id>`; creating/switching an account writes its keys into the standard slot (transparent to existing local code); before entering, the original standard-slot content is stashed to `bequest_pre_local_*` and restored on exit (`deactivateLocalProfile`) — cloud and local keys never overwrite each other
- **Data isolation**: LocalVault picks the file by current account — legacy accounts keep using `vault.bq` (old single-account installs migrate automatically, zero data movement); new accounts use `vault_<id>.bq`; cloud backups (no active account) still use `vault.bq`
- **Entry flow**: the local-mode entry is account selection → verify that account's master password (compare against a derivation from the account salt) → activate and enter; cold-start local-session restore also passes through the account-selection page (no more auto-release)
- Local-mode sorting/batch-moving operate directly inside the vault (repository implementation, no network dependency)

### ADR-20 Account password security

- **Changing the password after login**: `PUT /api/v1/me/password` (current-password check → new argon2id hash → audit)
- **token_version (migration 013)**: incremented on password change/reset; JWTs carry the version from signing time, and requireAuth/requireAdmin compare it against the DB — after a password change all old tokens are invalid immediately (no longer relying on the 24h TTL)
- **Forgot-password hardening**: `reset-request`/`reset` fall inside the strict rate-limit window; the code auto-invalidates after 5 wrong attempts (`password_resets.attempts`); codes are stored as sha256 hashes, 10-minute expiry, single-use, enumeration-resistant (nonexistent emails still return 200)
- **Master-password salt sync**: whenever changing/resetting the master password generates a new salt, `PUT /settings/master-salt` must sync it to the server, otherwise cross-device recovery on a new device derives with the old salt → false "wrong master password" (a companion invariant of ADR-17)
- **Non-destructive master-password change**: per asset, re-wrap `asset_key_wrapped_mk` with the new MK (credential ciphertext and WK wrapping preserved as-is) — together with the destructive reset (which clears credentials), this yields two paths: "change" when you remember the old password, "reset" when you've forgotten it

### ADR-7 Import/export (pure client-side E2E)

- Export/import happens entirely on the client: pull ciphertext → verify the master password (derive and compare against the local MK; the salt is saved at registration as `bequest_master_salt`) → decrypt/encrypt → JSON v1 file
- The server never sees plaintext (consistent with ADR-1); categories are mapped by name (preset → null, custom → match/create)
- Export scope: all / currently-filtered category (a single asset can reuse the same builder function)

### ADR-6 Reminder channels and email

- In-app messages (reminders table) are the default channel — the app pulls them, zero external dependencies
- SMTP email goes through the standard-library `net/smtp`; when env `SMTP_HOST/PORT/USER/PASS/FROM` is unconfigured it's skipped with a log line (free-tier inheritance reminders use the email channel and need SMTP configured to be deliverable)
- Push/SMS/phone: channel abstraction reserved; FCM/SMS APIs land in P3

### ADR-4 Asset storage model

- `name` plaintext (for list display/search); `encrypted_data` ciphertext (credentials/notes/key descriptions)
- `reminder_settings` JSON: per-asset reminder configuration (advance days/channel/template reference)
- Expiry/renewal date `expiry_date` plaintext, letting the server scheduler fire expiry reminders

### ADR-5 Audit log

- Server-side event records (who/did what/when) — the trust cornerstone for an inheritance product
- actor: `owner` / `inheritor:<id>` / `system`

## API conventions

- REST, prefix `/api/v1`
- Auth: `Authorization: Bearer <JWT>` (required by everything except register/login)
- Error responses: `{"error": "..."}`
- User isolation: every query is filtered by the `user_id` in the JWT; cross-account access is answered with 404/401
- Endpoints:
  - `GET /healthz`
  - `GET /api/v1/auth/captcha` (arithmetic captcha: `{"captcha_id","question"}`)
  - `POST /api/v1/auth/register`, `POST /api/v1/auth/login` (with captcha_id/captcha), `GET /api/v1/me`, `PUT /api/v1/me` (change username/email)
  - `GET /api/v1/auth/check?username=`, `GET /api/v1/auth/check-email?email=` (live duplicate check at registration)
  - `POST /api/v1/auth/reset-request` (email code), `POST /api/v1/auth/reset` (code-based password reset)
  - `GET|POST /api/v1/categories`, `DELETE /api/v1/categories/{id}` (deleted categories auto-null their assets' category_id)
  - `GET|POST /api/v1/assets`, `GET|PUT|DELETE /api/v1/assets/{id}`, `GET|POST /api/v1/assets/{id}/inheritors`, `DELETE /api/v1/assets/{id}/inheritors/{iid}`
  - `GET|POST|PUT|DELETE /api/v1/inheritors` (access codes stored as sha256 only, never returned)
  - `GET /api/v1/inheritors/{id}/assets` (every asset bound to that inheritor: asset-level + via category, with binding_id/binding_type for unbinding)
  - `GET|POST /api/v1/categories/{id}/inheritors`, `DELETE /api/v1/categories/{id}/inheritors/{iid}` (category-level inheritors, validating category ownership by the same user)
  - `GET|PUT /api/v1/settings/inheritance` (global inheritance toggle)
  - `GET|POST|PUT|DELETE /api/v1/reminder-templates` (system templates with `is_preset=1` are read-only)
  - `GET /api/v1/reminders`, `POST /api/v1/reminders/{id}/read`
  - `POST /api/v1/inheritance/claim` (no JWT; event_key + access_code) → asset-level events return `{"asset_key_wrapped_wk","asset_id","status"}`, whole-vault events return `{"master_key_wrapped","status"}`
  - `GET /api/v1/inheritance/status`, `GET /api/v1/audit-log`
  - `GET /api/v1/admin/stats`, `GET /api/v1/admin/users`, `GET|PUT|DELETE /api/v1/admin/users/{id}`, `GET /api/v1/admin/audit-log`, `GET|PUT /api/v1/admin/config` (requireAdmin)
  - `GET /admin` (embedded admin-console single page, unauthenticated — the page itself is just a static shell; all data access is API-authenticated)
- Asset lists omit `encrypted_data` (metadata only); a single asset includes the ciphertext base64; `encrypted_data` is the client-side AES-256-GCM output `base64(nonce‖ciphertext‖tag)`
- Asset requests/responses carry the optional `asset_key_wrapped_mk` / `asset_key_wrapped_wk` fields (empty strings are turned into NULL via nullable())
- Preset categories are client constants (not stored server-side); custom categories go through the API; choosing a preset means `category_id=null` (upgrade path: server-seeded categories)

## Key data flows

**Registration**: client derives MK → generates WK → wraps MK → fetches captcha → uploads `{username, email, password, master_key_wrapped, captcha_id, captcha}` → server validates the captcha + stores the argon2id password hash + the wrapped key

**Login**: fetch captcha → `{username|email, password, captcha_id, captcha}` → JWT → client unlocks the local library by deriving MK from the master password

**Inheritance trigger**: server scheduler detects the timeout → escalation reminders → emails the inheritor (including the access code) after trigger → inheritor claims `master_key_wrapped` with the codes
