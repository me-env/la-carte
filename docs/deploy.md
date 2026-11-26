# Deploy: the API on Dokploy

Owner: `cicd-lead` agent. The API (`api/`) runs as a single container behind Dokploy's Traefik,
with HTTPS on your domain and the SQLite deck on a persistent named volume. The phone (Ad Hoc build,
see `release.md`) and any MCP agent talk to the same deck.

```
docker-compose.yml (repo root)
  service "api"  build ./api  (api/Dockerfile: uv, Python 3.13 slim, non-root)
    listens 0.0.0.0:8000, not published on the host, Traefik reaches it on the Docker network
    env      LA_CARTE_API_TOKEN (required)  → Authorization: Bearer … on everything except /health and the icons
             LA_CARTE_PUBLIC_URL (optional) → https base URL; MCP serverInfo then lists <url>/icon.png
    volume   la-carte-data → /data/la-carte.db
```

## One-time setup in Dokploy

1. **Generate the token** on your Mac and keep it in your password manager:
   ```bash
   openssl rand -hex 32
   ```
2. **Create the service.** In a project → *Create Service* → **Compose** (type *Docker Compose*, not *Stack*).
3. **Provider** (General tab): GitHub (or Git with the SSH URL for a private repo), branch `main`,
   **Compose Path** `./docker-compose.yml`. The compose file sits at the repo root and builds `./api`, so
   nothing else is needed for the monorepo. Turn **Auto Deploy off**: CI deploys only after the API tests
   pass on that commit (`ci-cd.md`).
4. **Environment** tab: add
   ```
   LA_CARTE_API_TOKEN=<the token from step 1>
   ```
   Dokploy writes it to a `.env` next to the compose file, and the compose file passes it to the container.
   Deploys fail on purpose if it is missing.
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

## Backups

The whole deck is one SQLite file: `/data/la-carte.db` in the `la-carte-data` volume.

- **Automatic (recommended):** Dokploy → the compose service → *Volume Backups* → create one with
  service `api`, volume `la-carte-data`, a daily cron (`0 3 * * *`), and an S3 destination (set up first
  under Settings → S3 Destinations). Turn on *Turn off container* during the backup so SQLite is never
  copied in the middle of a write. It's a few seconds of downtime.
- **Manual, consistent snapshot** (SSH on the server, while the app runs):
  ```bash
  docker ps --filter "label=com.docker.compose.service=api" --format '{{.Names}}'   # find the la-carte one
  C=<that container name>
  docker exec "$C" python -c "import sqlite3; sqlite3.connect('/data/la-carte.db').backup(sqlite3.connect('/data/backup.db'))"
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
open unless `LA_CARTE_ALLOWED_EMAILS` is set. Full steps: `docs/specs/030-accounts-google-login.md`
("Self-hosting").

## Run the production image locally

```bash
LA_CARTE_API_TOKEN=$(openssl rand -hex 32) docker compose up --build    # no host port: add one to test
docker build -t la-carte-api api/ && docker run --rm -p 8000:8000 -e LA_CARTE_API_TOKEN=dev la-carte-api
```
CI (`.github/workflows/ci.yml`, job *API (docker build)*) builds the same image and checks `/health`.

Known local issue: on Apple M4 Macs with an older Docker Desktop, the arm64 container can crash
right away with exit code 132 (SIGILL). The Linux VM advertises SME, and the `cryptography` wheel
(pulled in by `mcp`) dies when it probes for it. Servers aren't affected. Locally, update Docker
Desktop or run with `--platform linux/amd64`.
