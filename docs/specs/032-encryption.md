# 032 — Encryption at rest: SQLCipher with a server key

Status: ready (032a only; built on the `accounts` branch: d06f796, review fixes 278fb88. App Store blocker)
Owners: api-engineer → code-reviewer → qa-validator; marketing (privacy wording, with 030h); the manager asks the
user for the server key
Depends on: 030a (on `accounts`).
Design reference: none (no screen).

## Goal
The whole database is encrypted on disk: **a stolen database file, a backup or a copy of the volume is unreadable**
without the server key. Always on (user decision 2026-11-28: no toggle).

This is **encryption at rest**, not end-to-end encryption. The server holds the key and decrypts in memory, so the
operator and the running server can read the data, as they must to serve the app and the agents (MCP, search,
duplicate checks, scheduling all run on the server).

## What it protects against (this table feeds `/privacy`)
| Threat | Protected? |
|---|---|
| A stolen database file, backup or volume copy, without the server's env | **Yes**: nothing is readable, not even emails or dates |
| A copy of the database **and** the server key (disk + env, e.g. a Dokploy compromise) | No: everything is readable |
| The operator (holds the key and the database) | No: can read every user's data. Policy, not cryptography, keeps them out (030h "Who can see it") |
| A compromised running server | No |
| A leaked token of a user | No: that token reads that user's deck until it is revoked or expires |

## Why SQLCipher
One setting covers every table, index, journal, temporary file and backup copy, with no code per column and nothing
to forget when a column is added. It is the standard encrypted SQLite (AES-256); the Python binding `sqlcipher3`
ships wheels for Python 3.13 on macOS arm64 and Linux x86_64/aarch64 (checked on PyPI 2026-11-28; it bundles
SQLCipher), and SQLAlchemy drives it as a `sqlite3`-compatible module. Cost: one native dependency, and `sqlite3` on
the command line can't open the file (use `sqlcipher` with the key).

## Rejected: a per-user key (user, 2026-11-28)
An earlier version of this spec (032b API, 032c iOS) added a per-user data key, wrapped under an account key kept
in iCloud Keychain and under each token, with agents approved in the app. Rejected: every agent over a remote MCP
needs the server to hold the user's key during its requests (the key that "is supposed to stay on the device" still
reaches the server), and phone AI apps can only use remote MCP. It added screens, states and a recovery-key risk
without keeping the key off the server. Backlog #72 records it.

---

## 032a — Base layer: SQLCipher (API)
Owner: api-engineer. Files: `db.py`, `config.py`, `pyproject.toml`, `docker-compose.yml`, `docs/deploy.md`. Built and
merged into `accounts` (2d619a8); ships with the accounts deploy.

### Decisions
1. **Dependency** `sqlcipher3` (≥ 0.6.5, bundles SQLCipher). The engine uses it as the DB-API module
   (`create_engine("sqlite://…", module=sqlcipher3.dbapi2)` or `creator=`), with a `connect` event that runs
   `PRAGMA key` first on every connection (registered with `insert=True`, so it runs before any other listener).
   In-memory `sqlite://` (unit tests) keeps plain `sqlite3`.
2. **`LA_CARTE_DB_KEY`** (64 hex). Required when `LA_CARTE_PUBLIC_URL` is set and not loopback (production): missing
   or malformed → refuse to start ("Set LA_CARTE_DB_KEY: 64 hex characters, e.g. openssl rand -hex 32"). Unset on a
   local or loopback server → plain SQLite as today (dev, e2e). A `LA_CARTE_PUBLIC_URL` without a parseable host
   (e.g. no scheme) counts as production, the safe side. The value is never logged.
3. **Encrypting an existing file** (startup, before every schema migration): if the key is set and the file is
   plaintext (it starts with `SQLite format 3\0`): `ATTACH '<db>.encrypting' AS enc KEY "x'<hex>'"`, `SELECT
   sqlcipher_export('enc')`, `DETACH`, reopen `.encrypting` with the key and compare row counts per table, then rename
   the original to `<db>.pre-032-<timestamp>.bak` and `.encrypting` to `<db>`. Log: "database encrypted; the
   plaintext copy <name> stays until you delete it". Leftover `<db>.encrypting*` files (a crash mid-export) are
   removed before a new attempt. A wrong key on an encrypted file → refuse to start ("LA_CARTE_DB_KEY doesn't open
   this database"), file untouched; only SQLCipher's "file is not a database" error reads as a wrong key, any other
   error is raised as is.
4. **Rekey**: with `LA_CARTE_DB_KEY_NEW` set, startup opens with `LA_CARTE_DB_KEY`, runs `PRAGMA rekey`, logs "rekeyed:
   set LA_CARTE_DB_KEY to the new value and remove LA_CARTE_DB_KEY_NEW". If `LA_CARTE_DB_KEY` no longer opens the file
   but `LA_CARTE_DB_KEY_NEW` does (a restart before the env was swapped), it opens with the new key and logs the same.
   If after `PRAGMA rekey` the new key doesn't open the file, refuse to start (never run on a half-rekeyed file).
5. Later migration backups (`_rebuild_if`'s `.bak` copies) are file copies of the encrypted file: encrypted.
6. `docs/deploy.md`: the variable, how to generate it, **keep a copy in a password manager (losing it loses every
   account)**, how to open the file for debugging (`sqlcipher <db>` then `PRAGMA key = "x'…'";`), rekey.

### Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| A1 | With `LA_CARTE_DB_KEY` set, a new database file does not start with `SQLite format 3`; opening it with `sqlite3` fails; the API serves REST and `/mcp` normally | pytest |
| A2 | A plaintext database with data + the key: after startup the file is encrypted, every table has the same rows, a `.pre-032-*.bak` equals the old file; a second start changes nothing (no new backup) | pytest |
| A3 | Wrong key on an encrypted file → refuses to start with the message of decision 3; the file is byte-for-byte unchanged | pytest |
| A4 | `LA_CARTE_PUBLIC_URL=https://example.com` without the key, or a key that isn't 64 hex → refuses to start; loopback/unset URL without the key → starts on plain SQLite | pytest |
| A5 | Rekey: start with `KEY=k1, KEY_NEW=k2` → the file opens with k2 only; a restart with the same env still starts; `KEY=k2` alone starts | pytest |
| A6 | No log line of a full test run contains the key's hex (caplog) | pytest |
| A7 | **Raw file scan**: seed users (emails `alice-marker@example.com`, …), notes, a report, feedback `feedback-marker`, activity; close the engine; the bytes of the db file and every `-wal`/`-journal`/`.bak` next to it (except `.pre-032-*`) contain none of the seeded strings, emails or token prefixes | pytest |
| A8 | The Docker image builds and `/health` answers with the key set (CI's image build) | CI |

## Privacy wording and App Store answers
- `/privacy` (030h) gains "How your data is protected": encrypted at rest with a server key, a stolen file or backup
  is unreadable, the server and so the developer who runs it can technically read the data, not end-to-end, and the
  threat table above in plain words. The copy is marketing's draft on `web-030h` (69cc2e8,
  `docs/marketing/web-landing.md`); 030h AC 4 checks "encrypted at rest" and "not end-to-end encryption". Never
  claim that the operator can't read the deck.
- App Privacy: unchanged categories (content is stored and processed on our server, so it is "collected").
  Export compliance: the app adds no encryption of its own, `ITSAppUsesNonExemptEncryption` stays `NO`.

## Out of scope
- Per-user or end-to-end encryption (rejected above, backlog #72). Encrypting individual columns.
- The access-log query-string filter: built in 030b (its decision 12), not here.

## What the user provides (the manager asks once)
- **U1** Approve putting a new secret `LA_CARTE_DB_KEY` (`openssl rand -hex 32`) in Dokploy, and keep a copy in their
  password manager: if it is lost, every account's data is lost.
- **U2** After checking the deployed deck: delete the plaintext files `*.pre-030-*.bak` and `*.pre-032-*.bak` on the
  server volume (the manager can do it with the user's OK), and accept that Dokploy volume backups taken before the
  deploy hold the plaintext deck until they age out (≤ 30 days).
