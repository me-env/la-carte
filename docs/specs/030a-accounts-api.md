# 030a — Accounts (API): users, scoped data, migration, bearer tokens

Status: ready
Owners: api-engineer → code-reviewer → qa-validator
Depends on: the `api/**` work in flight (028 `next` labels, 029 `activityevent`) merged first: this spec touches every
`deck` function and adds a `user_id` to 029's table. Overview and principles: [030](030-accounts-google-login.md).
Design reference: none (no screen).

## Goal
The API serves several people, each with their own deck, and nobody can ever reach another person's data. Today's
deck becomes the owner's account and today's static token becomes the owner's personal access token (PAT), so the
user's app, widget and agents keep working with no change. No Google yet (030b).

## User stories
- As the user, I deploy this and my app, widget and Claude keep working with the token they already have.
- As a second user, I see only my deck; ids from someone else's deck behave as if they didn't exist.
- As the user, I can delete my account and everything in it with one call.

## Decisions
1. **Tables** (new, created by `create_all`; `user` is quoted in SQL or named `account` if SQLModel needs it):
   - `user {id UUID pk, email str (casefolded, verified; unique), created_at, last_seen_at}`. No name, no picture.
   - `identity {provider str, subject str, user_id → user.id ON DELETE CASCADE, created_at}`, pk `(provider,
     subject)`. Empty until 030b.
   - `apitoken {id UUID pk, user_id → user.id ON DELETE CASCADE (indexed), kind: access|refresh|pat, hash str
     (SHA-256 hex of the full token; unique), scope: deck|stats, name str|null (PATs), client_id str|null,
     family_id UUID|null (refresh rotation, 030b), expires_at|null, created_at, last_used_at|null,
     revoked_at|null}`.
2. **`user_id` everywhere**: `note`, `card`, `reviewlog`, `report`, `feedback`, `activityevent` get `user_id UUID NOT
   NULL` + an index (`card` gets `(user_id, due)`). `settings` is rebuilt as `{user_id pk, new_cards_per_day}`.
   `card.user_id` always equals its note's (set by `deck`, checked by a test).
3. **Scoping in `deck`**: every public `deck` function takes `user_id: UUID` (keyword-only, required, right after
   `session`) and every `select` / `get` filters on it (a `session.get` is followed by a `user_id` check). Inserts
   set it. Another user's id is "not found" (`NotFound` → 404 / `ToolError` "… not found"), never "forbidden".
   Duplicate detection, the queue, burying, `stats`, the ladder, streak, load balancing (the due-count query of
   spec 023), reports, feedback, activity and the milestone are all per user. Activity ingest (029): an event id
   that already exists **for another user** counts as `rejected`, not `duplicates`.
4. **Who is calling** (`auth.py`, new): `verify(session, raw_token, now) -> Principal | None` where
   `Principal = {user_id, scope, client_id, token_id, kind}`. Looks up `sha256(raw)` in `apitoken`, rejects revoked,
   expired, and `kind = refresh`. Updates `last_used_at` at most once per hour per token. Token format:
   `lc_<at|rt|pat>_` + 43 base64url chars from `secrets.token_urlsafe(32)`. `mint(session, user_id, kind, scope,
   …) -> raw` returns the token once and stores only the hash.
   - **REST**: a FastAPI dependency `CurrentUser` on every route except `PUBLIC_PATHS` (`/health`, icons; 030b adds
     its own). Missing / bad token → 401 `{"detail": "Unauthorized"}` + `WWW-Authenticate: Bearer`. A `stats`
     token is accepted only on `GET /stats` (else 403 `{"detail": "Insufficient scope"}`).
   - **MCP**: the MCP server gets `token_verifier=` (SDK `TokenVerifier`) built on `verify`, returning
     `AccessToken(token, client_id, scopes, expires_at, resource=<PUBLIC>/mcp, subject=str(user_id))`, with
     `AuthSettings(issuer_url=<PUBLIC>, resource_server_url=<PUBLIC>/mcp, required_scopes=["deck"])`. `run(op, …)`
     in `mcp_server.py` reads `get_access_token().subject` and passes `user_id`. A `stats` token can't use `/mcp`.
     030b swaps `token_verifier` for the full `auth_server_provider`, keeping `verify` underneath.
   - `<PUBLIC>` = `LA_CARTE_PUBLIC_URL`, else `http://<host>:<port>` (local, tests).
   - `BearerTokenMiddleware` and the "no token configured = open" mode are **removed**: every request resolves to a
     user. Local dev: start once with `LA_CARTE_OWNER_EMAIL` + `LA_CARTE_API_TOKEN` (below).
5. **Owner + legacy token** (startup, after migrations, idempotent):
   - When `LA_CARTE_OWNER_EMAIL` is set and no user has that email, create it (no identity).
   - When `LA_CARTE_API_TOKEN` is also set and the owner has **no** PAT named `legacy` (revoked ones count), store
     it as the owner's PAT `legacy`, scope `deck`, no expiry. Otherwise the variable is ignored, with one log line
     "LA_CARTE_API_TOKEN already imported; you can remove it". The token value is never logged.
   - `LA_CARTE_API_TOKEN` without `LA_CARTE_OWNER_EMAIL` → refuse to start ("set LA_CARTE_OWNER_EMAIL").
6. **Migration 030** (`db._migrate`, through `_rebuild_if`; condition: `note` exists and has no `user_id`):
   - Backup `<db>.pre-030-<timestamp>.bak`, one transaction (pattern of 014/021).
   - If any of `note`, `card`, `reviewlog`, `report`, `feedback`, `activityevent`, `settings` has a row and
     `LA_CARTE_OWNER_EMAIL` is unset → abort before the backup, refuse to start with
     "This deck has data: set LA_CARTE_OWNER_EMAIL to the Google email of its owner". Nothing changes.
   - Else: create the `user` row for the owner (if data exists), add `user_id` to each table (rebuild where SQLite
     needs it), set every row's `user_id` to the owner, rebuild `settings` keyed by `user_id` (row 1 → owner).
     Ids, FSRS state, reviews, reports untouched.
   - A database with no data migrates with no user row.
7. **`GET /me`** → `{id, email, created_at}` (`MeRead`). **`DELETE /me`** → 204: in one transaction deletes every
   row with that `user_id` in every owned table (including `reviewlog`: "history is never deleted" holds within a
   deck, not past its owner), its `apitoken`s, `identity` rows and the `user`. Any `deck` scope token can call it.
   No MCP tool for deletion (agents must not delete an account).
8. **PAT listing and revocation** (REST only): `GET /me/tokens` → `[{id, name, scope, created_at, expires_at,
   last_used_at}]` (PATs only, not revoked, newest first; never the token or its hash); `DELETE /me/tokens/{id}` →
   204 (sets `revoked_at`; unknown or another user's → 404). Creating PATs (`POST /me/tokens`) is 030b (it needs
   the app's OAuth token).
9. `docker-compose.yml`: `LA_CARTE_API_TOKEN` becomes optional, `LA_CARTE_OWNER_EMAIL` is passed through.
   `docs/deploy.md`: the new env vars and the deploy order (owner email first).

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | A request to any REST route but `/health` and the icons without `Authorization`, with an unknown token, a revoked PAT or an expired PAT → 401 `{"detail": "Unauthorized"}` with `WWW-Authenticate: Bearer` | pytest |
| 2 | `/mcp` without a valid token → 401 whose `WWW-Authenticate` holds `resource_metadata=`; with a valid `deck` PAT `tools/list` works over HTTP | pytest |
| 3 | A `stats` PAT gets 200 on `GET /stats`, 403 on `GET /notes`, 401/403 on `/mcp` | pytest |
| 4 | **Cross-user matrix**: users A and B, each with notes, cards, reviews, a report, feedback, activity, a milestone. For **every** REST route and **every** MCP tool, B using A's ids gets 404 / `ToolError` "not found", B's lists/stats/queue/activity/feedback/reports contain nothing of A's, and A's data is byte-for-byte unchanged afterwards. The test enumerates `app.routes` and the MCP tool list and **fails when a route or tool has no case** | pytest |
| 5 | Per-user behavior: B adding a basic note whose front equals one of A's is not skipped as a duplicate; A's due cards don't count in B's `stats.due`, `history`, `streak`, ladder or spec 023 day counts; `new_card_milestone` set by A leaves B at 15 | pytest |
| 6 | Every `card.user_id` equals its note's `user_id` after `add_notes`, `add_direction`, `PATCH /notes` | pytest |
| 7 | Migration: a pre-030 database file with data + `LA_CARTE_OWNER_EMAIL` starts; a `.pre-030-*.bak` exists and equals the old file; every row belongs to the owner; ids, FSRS fields, review logs, reports and the milestone are unchanged; a second start changes nothing (no new backup) | pytest |
| 8 | The same database **without** `LA_CARTE_OWNER_EMAIL` refuses to start with the message of decision 6 and is left untouched (no backup, no change) | pytest |
| 9 | With `LA_CARTE_API_TOKEN=x`, that token works on REST and `/mcp` as the owner after migration; the database holds only its SHA-256; restarting with it still set creates no second PAT; after `DELETE /me/tokens/{legacy id}` it gets 401 and a restart with the variable still set does **not** bring it back | pytest |
| 10 | `GET /me` returns the caller's `{id, email, created_at}`; `DELETE /me` → 204, then every table holds zero rows with that `user_id`, the caller's tokens get 401, and the other user's data and tokens are untouched | pytest |
| 11 | `GET /me/tokens` lists the caller's live PATs without `token`/`hash`; `DELETE /me/tokens/{id}` of another user's PAT → 404 | pytest |
| 12 | No token, token hash or email appears in the log output of a full test run (caplog check on the auth paths) | pytest |
| 13 | `scripts/e2e.sh` (qa-validator) starts its APIs with `LA_CARTE_OWNER_EMAIL=e2e@example.com` + `LA_CARTE_API_TOKEN=e2e-token` and the existing live UI tests pass unchanged | UI (live) |
| 14 | The user's deployed app, widget and Claude Code (`--header` with the old token) work unchanged after deploy (manager checks with the user) | manual |

## API / MCP changes
- New: `GET /me`, `DELETE /me`, `GET /me/tokens`, `DELETE /me/tokens/{id}`. Every route now requires a token and
  is scoped. No response shape changes elsewhere.
- MCP: same tools, same shapes, scoped to the token's user. Docstrings unchanged except "the user's deck" wording
  where they said "the deck".
- iOS: no change needed (the stored token keeps working); `MeRead` is added to `APIClient` + `DecodingTests` by
  030c.

## Accessibility identifiers
None.

## Out of scope
- Google, `/authorize`, `/token`, `POST /me/tokens` (030b). App UI (030c, 030d). Admin roles. Rate limiting.
