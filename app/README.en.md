# Bequest (托孤) client

> 中文版: [README.md](README.md)

Flutter client for the digital asset vault: the same codebase compiles to **Android + Web**. End-to-end encryption, app lock, local mode, self-hosted sync (WebDAV/S3), inheritance handover, and a bilingual (中文/English) UI.

> Server: [../server/README.en.md](../server/README.en.md) · repo overview: [../README.en.md](../README.en.md)

## Technical highlights

- **End-to-end encryption**: the master password derives an AES-256 master key via Argon2id; asset sensitive fields are encrypted before upload, the server never sees plaintext.
- **Key derivation**: Android/desktop use pointycastle (pure Dart); Web uses self-hosted WASM (`web/assets/hash-wasm.js`, ~0.3s).
- **Local mode**: usable without logging in (multiple local accounts, encrypted local vault).
- **Self-hosted sync**: WebDAV/S3 encrypted backups; credentials are stored only on this device.
- **Platform storage abstraction**: io/web dual implementations under `lib/platform/` (string_store / file_share).
- **中文/English**: dictionary in `lib/l10n/app_l10n.dart` + language switch on the settings page.

## Environment requirements

- Flutter 3.44+ (stable), Dart 3.12+
- Android: JDK 17, Android SDK (release builds require a signing keystore)
- China mirrors (optional): `PUB_HOSTED_URL=https://pub.flutter-io.cn`, `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`

## Running and connecting to a backend

```bash
cd app
flutter pub get

# Connect to a local backend (emulators reach the host via 10.0.2.2)
flutter run                      # default Android emulator; once the login page loads, enter http://10.0.2.2:8080 as the server address

# Debug against a specific backend address directly (use the LAN IP on a physical Android device)
# Login page/settings → server address is editable; release builds already include network permission and cleartext-HTTP support
```

The Web build is usually served same-origin by the server (no need to run it separately):

```bash
flutter build web                # output lands in build/web
cd ../server && go run .         # open http://localhost:8080 in a browser
```

## Tests and checks

```bash
flutter analyze                  # static analysis (a few known false positives for web-only conditional imports under the VM)
flutter test                     # unit/widget tests (33 files under test/)
flutter build web                # Web build output
flutter build apk --debug        # Android debug
flutter build apk --release      # Android release (requires signing config; see the release section in the repo-root README)
```

## Directory structure

```
lib/
├── main.dart             # entry point: theme/language/routes/app lock (LockGate)
├── api/                  # HTTP client, API config (server address)
├── crypto/               # master-password derivation, encryption/decryption, recovery key
├── l10n/                 # Chinese/English translation dictionaries
├── models/               # data models
├── pages/                # pages (login/home/assets/inheritance/settings/sync…)
├── platform/             # platform abstraction (io/web conditional imports)
├── repository/           # cloud/local asset repositories (RepositoryFactory)
├── storage/              # secure storage (Keystore/localStorage), LocalVault
├── sync/                 # WebDAV/S3 self-hosted sync, scheduled auto-backup
├── utils/ widgets/       # utilities and shared widgets
test/                     # unit and widget tests
```

## Feature overview

Asset CRUD/groups/trash/search · expiry reminders · inheritance (asset-level/group-level/global toggle/claim status) · import/export (JSON/encrypted .beq/Excel) · app lock (PIN/pattern/biometrics) · multiple local accounts · WebDAV/S3 encrypted backups · membership benefits · bilingual UI
