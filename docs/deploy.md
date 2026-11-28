# Deploy: the API on Dokploy

Owner: `cicd-lead` agent. The API (`api/`) runs as a single container behind Dokploy's Traefik,
with HTTPS on your domain and the SQLite deck on a persistent named volume. The phone (Ad Hoc build,
see `release.md`) and any MCP agent talk to the same deck.

```
docker-compose.yml (repo root)
  service "api"  build ./api  (api/Dockerfile: uv, Python 3.13 slim, non-root)
    listens 0.0.0.0:8000, not published on the host, Traefik reaches it on the Docker network
    env      LA_CARTE_OWNER_EMAIL (required with data or a token) → the account that owns the deck (spec 030a)
             LA_CARTE_API_TOKEN (optional)  → imported at the first accounts start as the owner's PAT `legacy`
             LA_CARTE_PUBLIC_URL (optional) → https base URL: OAuth issuer, MCP resource <url>/mcp, icon
             LA_CARTE_DB_KEY (required with a public URL) → SQLCipher key of the whole database file (spec 032a)
             LA_CARTE_DB_KEY_NEW (only to rotate) → the new key; the start rekeys the file (see below)
             LA_CARTE_GOOGLE_CLIENT_ID, _SECRET (both or neither) → Google sign-in (spec 030b); unset = off
             LA_CARTE_SIGNUP (default open)  → `open`, or `allowlist`: only LA_CARTE_ALLOWED_EMAILS + the owner
             LA_CARTE_ALLOWED_EMAILS (allowlist only) → comma-separated emails
             LA_CARTE_SUPPORT_EMAIL, LA_CARTE_OPERATOR_NAME (optional) → support and privacy pages (spec 030h)
    auth     every request but /health and the icons: Authorization: Bearer <a user's token>
    volume   la-carte-data → /data/la-carte.db
```

## One-time setup in Dokploy

1. **Generate the token and the database key** on your Mac (two separate runs) and keep both in your
   password manager:
   ```bash
   openssl rand -hex 32     # the token
   openssl rand -hex 32     # the database key (LA_CARTE_DB_KEY)
   ```
   **The database key is the only way to read the deck.** Keep a copy **offline**, outside the server and
   outside Dokploy (password manager, plus a printed or offline copy): if Dokploy, the server or its env are
   lost, the volume and every backup are unreadable without it, for every account. Nobody can recover it.
2. **Create the service.** In a project → *Create Service* → **Compose** (type *Docker Compose*, not *Stack*).
3. **Provider** (General tab): GitHub (or Git with the SSH URL for a private repo), branch `main`,
   **Compose Path** `./docker-compose.yml`. The compose file sits at the repo root and builds `./api`, so
   nothing else is needed for the monorepo. Turn **Auto Deploy off**: CI deploys only after the API tests
   pass on that commit (`ci-cd.md`).
4. **Environment** tab: add
   ```
   LA_CARTE_OWNER_EMAIL=<the email of your Apple or Google account>
   LA_CARTE_API_TOKEN=<the token from step 1>
   LA_CARTE_DB_KEY=<the database key from step 1>
   LA_CARTE_PUBLIC_URL=https://<your API host>
   LA_CARTE_GOOGLE_CLIENT_ID=<Google "Web application" client id>   # sign-in (spec 030b)
   LA_CARTE_GOOGLE_CLIENT_SECRET=<its secret>
   LA_CARTE_SIGNUP=allowlist                                        # optional, default open
   LA_CARTE_ALLOWED_EMAILS=<a@example.com,b@example.com>            # allowlist only
   LA_CARTE_SUPPORT_EMAIL=<contact email>                           # web pages (spec 030h)
   LA_CARTE_OPERATOR_NAME=<who runs the service>
   ```
   Without both Google values the API starts with Google sign-in off (personal access tokens only); Google
   sign-in also needs `LA_CARTE_PUBLIC_URL` with https. Only variables listed in `docker-compose.yml` reach
   the container: a new setting needs a line there too.
   Dokploy writes them to a `.env` next to the compose file, and the compose file passes them to the
   container. At its first start the API creates the owner's account and stores the token (hashed) as the
   owner's personal access token `legacy`; after that the token variable is ignored and can be removed.
   The import happens only on that first start (the one that creates the accounts tables, or migrates
   to them): revoking `legacy`, deleting the owner's account (`DELETE /me`) or changing
   `LA_CARTE_OWNER_EMAIL` later never brings the token back, even if the variable is still set.
   **Order for an existing deck (spec 030a):** set `LA_CARTE_OWNER_EMAIL` *before* deploying the accounts
   version. A database with data refuses to start without it (log: "This deck has data: set
   LA_CARTE_OWNER_EMAIL …") and is left untouched; with it, migration 030 backs the file up
   (`la-carte.db.pre-030-<timestamp>.bak`) and gives every row to the owner. Keep `LA_CARTE_API_TOKEN` for
   that first start, so the app, widget and agents keep working on the same token.
   See "Database encryption" below for what `LA_CARTE_DB_KEY` does on the first start.
5. **Domains** tab → *Add Domain*: service `api`, host e.g. `carte.example.com`, path `/`, **container
   port `8000`**, HTTPS on, certificate *Let's Encrypt*. Point the DNS A record of that host at the
   server first. Dokploy adds the Traefik labels itself, so the compose file has none. (Free `sslip.io`
   domains are HTTP only, so use a real domain: the phone and MCP send the token, and it must not travel
   over plain HTTP.)
6. **Deploy**, then check:
   ```bash
   URL=https://carte.example.com TOKEN=…           # your values
   curl -s $URL/health                              # {"status":"ok","build":"…"}  (no token needed)
   curl -s -o /dev/null -w '%{http_code}\n' $URL/cards                                   # 401
   curl -s -H "Authorization: Bearer $TOKEN" $URL/cards                                  # [...]
   ```
7. **Did the deploy land?** `/health` reports `build`, a hash of the API's Python source. Compare it with
   your working tree (no token needed; exit 0 = up to date, 1 = behind):
   ```bash
   scripts/api-live-check.sh $URL        # or: export LA_CARTE_LIVE_URL=$URL; scripts/api-live-check.sh
   ```

**Keep the volume.** The deck lives only in the named volume `la-carte-data`. Redeploys and image
rebuilds keep it. Don't switch it to a bind mount or an absolute host path (Dokploy cleans those), and
don't delete the service's volumes when you remove or recreate the service.

### Why no proxy or host settings are needed

- The image sets `FORWARDED_ALLOW_IPS=*`, so uvicorn trusts Traefik's `X-Forwarded-For/Proto` (proxy
  headers are on by default). That's safe because port 8000 is never published, so only Traefik can reach it.
- The MCP endpoint has DNS-rebinding (Host header) protection off (`api/src/la_carte_api/app.py`). Access is
  controlled by the bearer token, so it accepts your public hostname as is.

## Database encryption (spec 032a)

The whole SQLite file (every table, index and journal, and the API's own `.bak` copies) is encrypted with
SQLCipher (AES-256) under `LA_CARTE_DB_KEY`: 64 hex characters, `openssl rand -hex 32`. It lives only in
Dokploy's env and in your offline copies, never in the repo.

- **Required in production.** With `LA_CARTE_PUBLIC_URL` set to a non-loopback URL, the API refuses to start
  without it, or with a value that isn't 64 hex ("Set LA_CARTE_DB_KEY: 64 hex characters, e.g. openssl rand
  -hex 32"). Locally (no public URL, or a loopback one) and without the key, it runs on plain SQLite. The value
  is never logged.
- **Losing it loses every account.** No key, no deck: not for you, not for the users. Keep it in your password
  manager **and** an offline copy before the first deploy with it.
- **First start on an existing plaintext deck:** the API encrypts the file before any migration, checks that
  every table kept its rows, and keeps the plaintext original as `la-carte.db.pre-032-<timestamp>.bak` (log:
  "database encrypted; the plaintext copy … stays until you delete it"). Later starts do nothing. Once you have
  checked the deployed deck, **delete the plaintext copies** (`*.pre-030-*.bak`, `*.pre-032-*.bak`) from the
  volume: they are the only unencrypted data left (with volume backups taken before the deploy, which age out).
- **Wrong key:** the API refuses to start ("LA_CARTE_DB_KEY doesn't open this database") and leaves the file
  untouched. An encrypted file with no key set refuses too ("This database is encrypted: set LA_CARTE_DB_KEY").
- **Rotate the key:** generate a new one, save it offline, set `LA_CARTE_DB_KEY_NEW=<new>` next to the current
  `LA_CARTE_DB_KEY` and redeploy. The start rekeys the file and logs "rekeyed: set LA_CARTE_DB_KEY to the new
  value and remove LA_CARTE_DB_KEY_NEW": do that, redeploy. A restart in between is fine (it opens with the new
  key). Backups taken before the rotation still need the old key: keep it until they age out (30 days).
- **Open the file for debugging** (`sqlite3` can't): with the `sqlcipher` CLI (`brew install sqlcipher`, or the
  distro package) on a copy of the file:
  ```
  sqlcipher la-carte.db
  sqlite> PRAGMA key = "x'<the 64 hex>'";
  sqlite> .tables
  ```
  Avoid typing the key where your shell history keeps it.

## Backups

The whole deck is one SQLite file, encrypted (above): `/data/la-carte.db` in the `la-carte-data` volume. Every
backup is encrypted the same way: it needs `LA_CARTE_DB_KEY` (the one current when it was taken) to restore.

- **Automatic (recommended):** Dokploy → the compose service → *Volume Backups* → create one with
  service `api`, volume `la-carte-data`, a daily cron (`0 3 * * *`), and an S3 destination (set up first
  under Settings → S3 Destinations). Turn on *Turn off container* during the backup so SQLite is never
  copied in the middle of a write. It's a few seconds of downtime.
- **Manual, consistent snapshot** (SSH on the server, while the app runs):
  ```bash
  docker ps --filter "label=com.docker.compose.service=api" --format '{{.Names}}'   # find the la-carte one
  C=<that container name>
  docker exec -i "$C" python - <<'EOF'    # an encrypted copy, same key
  import os, sqlcipher3
  db = sqlcipher3.connect("/data/la-carte.db")
  db.execute("PRAGMA key = \"x'%s'\"" % os.environ["LA_CARTE_DB_KEY"])
  db.execute("VACUUM INTO '/data/backup.db'")
  EOF
  docker cp "$C":/data/backup.db ./la-carte-$(date +%F).db && docker exec "$C" rm /data/backup.db
  ```
  To restore, stop the service, copy the file back to `/data/la-carte.db` in the volume, then start it.

## Connect Claude Code (MCP)

```bash
claude mcp add --transport http la-carte https://carte.example.com/mcp \
  --header "Authorization: Bearer <token>"
```
Then ask "add these words to my deck". `claude mcp list` should show `la-carte` as connected.

## Point the iPhone app at it

Today (spec 008): Deck → gear icon → URL `https://carte.example.com`, token, then *Test connection*
("Connected · N cards"). Until both are set the app shows "Connect your deck" with an "Open Settings" button.

From accounts (spec 030c) the app has **no server setting**: it talks only to the URL baked in at build time
(`LA_CARTE_DEFAULT_API_URL`; the App Store build points at the hosted server). To self-host, build the app from
source with `LA_CARTE_DEFAULT_API_URL = https://carte.example.com` in `ios/Config/Signing.local.xcconfig`, and
register your own Google OAuth client ("Web application", redirect URI
`https://carte.example.com/oauth/callback`) for the API's `LA_CARTE_GOOGLE_CLIENT_ID` / `_SECRET`. Sign-up is
open by default (`LA_CARTE_SIGNUP=open`; `allowlist` + `LA_CARTE_ALLOWED_EMAILS` to restrict it). Full steps:
`docs/specs/030-accounts-google-login.md` ("Self-hosting").

## Accounts and web env (spec 030; not live yet)

All optional unless noted; secrets only in Dokploy, never in the repo. The full list with notes is in spec 030
("Secrets and env"); what the user provides and where it comes from is in its "What the user provides".
- Accounts: `LA_CARTE_OWNER_EMAIL` (required before 030a deploys on a deck with data), `LA_CARTE_PUBLIC_URL`
  (required, https), `LA_CARTE_DB_KEY` (required, spec 032a; `LA_CARTE_DB_KEY_NEW` only to rotate it), `LA_CARTE_GOOGLE_CLIENT_ID`, `LA_CARTE_GOOGLE_CLIENT_SECRET`, `LA_CARTE_SIGNUP`,
  `LA_CARTE_ALLOWED_EMAILS`.
- Sign in with Apple (030e, 030g): `LA_CARTE_APPLE_TEAM_ID`, `LA_CARTE_APPLE_KEY_ID`,
  `LA_CARTE_APPLE_PRIVATE_KEY_B64` (`base64 -i AuthKey_<KEYID>.p8 | tr -d '\n'`), `LA_CARTE_APPLE_BUNDLE_ID`,
  `LA_CARTE_APPLE_SERVICES_ID`.
- Web pages (030h): `LA_CARTE_SUPPORT_EMAIL`, `LA_CARTE_OPERATOR_NAME`, `LA_CARTE_APP_STORE_URL`. The landing page
  is `<PUBLIC>/`, the privacy policy `<PUBLIC>/privacy`, support `<PUBLIC>/support`: served by the same container.
- Volume backups: keep **30 days or less** (the privacy policy promises it).

## Run the production image locally

```bash
LA_CARTE_OWNER_EMAIL=dev@example.com LA_CARTE_API_TOKEN=$(openssl rand -hex 32) \
  LA_CARTE_DB_KEY=$(openssl rand -hex 32) docker compose up --build   # a throwaway key: local data only
docker build -t la-carte-api api/ && docker run --rm -p 8000:8000 -e LA_CARTE_OWNER_EMAIL=dev@example.com \
  -e LA_CARTE_API_TOKEN=dev -e LA_CARTE_DB_KEY=$(openssl rand -hex 32) la-carte-api   # no host port in compose: add one to test
```
CI (`.github/workflows/ci.yml`, job *API (docker compose)*) boots the API through `docker-compose.yml` with
throwaway values and checks `/health` and an authenticated `/me`.

Known local issue: on Apple M4 Macs with an older Docker Desktop, the arm64 container can crash
right away with exit code 132 (SIGILL). The Linux VM advertises SME, and the `cryptography` wheel
(pulled in by `mcp`) dies when it probes for it. Servers aren't affected. Locally, update Docker
Desktop or run with `--platform linux/amd64`.
