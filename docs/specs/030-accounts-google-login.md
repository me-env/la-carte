# 030 — Accounts: sign in with Google (overview)

Status: ready (overview; the work is in 030a → 030b → 030c)
Owners: api-engineer (030a, then 030b) ∥ ios-engineer (030c, against the contract below, on mock) → code-reviewer →
qa-validator
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg (one centered message + one
button, like 008's "Connect your deck"); Google's "Sign in with Google" branding guidelines for the button.

## Goal
la-carte opens to a few friends, then the App Store. Each person signs in with Google, gets **their own deck**, and
can plug the same server into any agent (Claude, ChatGPT, Cursor, …) as an MCP connector that also signs in with
Google. No frontend app: the API is its own OAuth 2.1 authorization server and delegates identity to Google.

## The split (do in this order)
| Spec | What | Lane | Ships |
|---|---|---|---|
| [030a](030a-accounts-api.md) | `user` + `identity` + `apitoken` tables, `user_id` on every owned table, every query scoped, migration (the deck → the owner, the static token → the owner's PAT), bearer verification for REST + `/mcp`, `GET/DELETE /me`, `GET/DELETE /me/tokens`, cross-user tests | `api/**` | Deploy alone: the user's app, widget and agents keep working on the old token (now the owner's PAT) |
| [030b](030b-oauth-google.md) | OAuth 2.1 authorization server (MCP SDK provider): metadata, DCR, `/authorize` → consent → Google → our code → `/token`, refresh rotation, `/revoke`, `POST /me/tokens`, allowlist, fake identity provider, `/privacy` | `api/**` after 030a | Deploy with the Google env vars; connect Claude |
| [030c](030c-ios-sign-in.md) | Sign-in screen, `ASWebAuthenticationSession`, Keychain session + refresh, widget token, Settings account section (sign out, delete account, privacy) | `ios/**`; can start with 030a on mock; ships after 030b is deployed | Ad Hoc build for friends |
| [030d](030d-ios-access-tokens.md) | Settings → "Access tokens": create (name, optional expiry), copy once, list, revoke | `SettingsFeature/**` after 030c | With or after 030c |

## Principles (also in `docs/architecture.md`)
1. **Never passwords.** la-carte stores no passwords or password hashes, and offers no password login, password
   reset or "magic link". Ever. Identity is always OAuth/OpenID Connect with an external provider.
2. **Google is the only identity provider for now.** The flow goes through one provider boundary
   (`identity.IdentityProvider`, 030b) so another OAuth provider (e.g. Apple) can be added later without reworking
   the flow, the token endpoints or the tables. Sign in with Apple is **not** specified or built now (see "App
   Store note").
3. **Take the minimum from Google (data minimisation).** We request only the `openid email` scopes: no `profile`,
   so no name and no picture. We store only Google's `sub` (the account key) and the **verified** email (for the
   optional sign-up allowlist and support). A Google sign-in whose `email_verified` is not `true` is rejected. We keep no
   Google access or refresh token: Google's code is exchanged once, the ID token is read, everything else is
   dropped (this also satisfies guideline 5.1.1(v): "An app may not store credentials or tokens to social networks
   off of the device").
4. **An account is identified by (provider, `sub`), never by email alone.** The email is a mutable attribute,
   refreshed at each sign-in. The one email-based step is claiming the owner row that migration 030 creates
   *without* an identity: the first verified sign-in with exactly `LA_CARTE_OWNER_EMAIL` attaches its identity. A
   row that already has an identity is never matched by email. A future provider links
   to an existing account by **signing in with it while already signed in** (Apple's relay emails would never
   match anyway), not by email matching.
5. **All tokens are ours, opaque, and stored hashed.** Access, refresh and personal access tokens are random
   256-bit strings minted by la-carte (prefixes `lc_at_`, `lc_rt_`, `lc_pat_`); the database stores only their
   SHA-256. Opaque tokens mean **no token-signing key** to manage: revocation is a row update.
6. **OAuth is the primary path; personal access tokens (PATs) are the secondary one.** Agents connect with OAuth
   (030b). PATs stay for scripts, CI/e2e and MCP clients without OAuth (`Authorization: Bearer lc_pat_…`). They are
   API tokens, **not passwords**: minted only by a user signed in with Google, **from the app** (`POST /me/tokens`
   accepts only an access token issued to the `la-carte-ios` client; a PAT or an agent's token can't mint one),
   scoped to that user, shown once, stored hashed, revocable, with an optional expiry. The app also mints one
   `stats`-scoped PAT for its widget. e2e gets its PAT the same way: a fake-provider sign-in as `la-carte-ios`, then
   `POST /me/tokens`.
7. **The legacy static token (`LA_CARTE_API_TOKEN`) is migrated to a PAT, not kept as a mode.** Migration 030
   stores it (hashed) as the owner's PAT `legacy`, then the variable is ignored. Why: one auth path to build, test
   and secure (every request resolves to a user through `apitoken`), the user's devices and agents keep working
   with zero change, and the owner can revoke it like any PAT. A "single-user self-host mode" would be a second
   code path (no users, unscoped queries) that every future feature must keep working. Self-hosters run the same
   server with their own Google client and `LA_CARTE_OWNER_EMAIL`.
8. **No token passthrough.** Google's tokens never reach `/mcp` or REST, and our tokens never go to Google
   (MCP authorization spec 2026-07-28, "Token passthrough" is forbidden).
9. **The API stays the single source of truth** and holds all auth logic. The only HTML it renders: the consent
   page for agent connectors, sign-in error pages, and `/privacy`. No separate frontend.
10. **Everyone sees only their own data, except the owner reads feedback** (user decision 2026-11-26). The owner
   (the `user` whose email equals `LA_CARTE_OWNER_EMAIL`; nobody when unset) gets, **over MCP only**: every user's
   feedback in `list_feedback` (each item carries its sender's `user_email`), `close_feedback` on any of it, and
   `activity_log(user=<email>)` for a user who has sent at least one feedback, scoped to that user. Nothing else is
   cross-user (deck, reviews, reports, stats, tokens), no admin UI, no REST route, no role table. `/privacy` says
   so (030b). Detail and tests in 030a.

## The flow
```
client (iOS app | Claude | ChatGPT | Cursor …)
  │ 1 GET /authorize?client_id&redirect_uri&code_challenge(S256)&state&scope=deck&resource=<PUBLIC>/mcp
  ▼
la-carte /authorize ── stores the pending request ──► agent clients: /oauth/consent (one click) ─┐
  │                                                     iOS client (built in): straight on ──────┤
  ▼                                                                                               ▼
accounts.google.com (scope "openid email", our state + nonce + PKCE, prompt=select_account)
  │ 2 redirect GET /oauth/callback?code&state
  ▼
la-carte: exchange Google's code (server-to-server, client secret) → ID token → check iss/aud/exp/nonce/
          email_verified → (google, sub) → user (allowlist) → mint OUR code → redirect
  │ 3 redirect_uri?code=<ours>&state=<client's>&iss=<PUBLIC>
  ▼
client POST /token (code + code_verifier) → {access_token lc_at_ (1 h), refresh_token lc_rt_ (rotated), …}
  │ 4 Authorization: Bearer lc_at_… on REST and /mcp
```
MCP discovery (spec revision 2026-07-28): `/mcp` without a valid token → 401 with
`WWW-Authenticate: Bearer resource_metadata="<PUBLIC>/.well-known/oauth-protected-resource/mcp", scope="deck"`;
the protected resource metadata names `<PUBLIC>` as authorization server; `<PUBLIC>/.well-known/oauth-authorization-server`
lists the endpoints. Clients register with Dynamic Client Registration (`/register`), the one method every common
client supports today (claude.ai, Claude Code, ChatGPT, Cursor); CIMD is backlog.

## API ↔ app contract (summary; detail in 030a/030b)
| Call | Shape |
|---|---|
| `GET /authorize` | as above, `client_id=la-carte-ios`, `redirect_uri=lacarte://oauth`, `resource=<base>/mcp` → browser → `lacarte://oauth?code&state&iss` or `lacarte://oauth?error=access_denied&error_description=not_allowed&state` |
| `POST /token` (form) | `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `code_verifier`, `resource` → `{access_token, token_type: "Bearer", expires_in: 3600, refresh_token, scope: "deck"}`; `grant_type=refresh_token`, `refresh_token`, `client_id` → same shape, **new** refresh token; errors `{error, error_description}` (dead refresh token → 400 `invalid_grant`) |
| `POST /revoke` (form) | `token`, `client_id` → 200 |
| `GET /me` | `{id, email, created_at}` |
| `DELETE /me` | 204; the account and everything it owns are gone |
| `POST /me/tokens` | `{name, scope: "deck" \| "stats", expires_in_days?: 1–365}` (only with an `la-carte-ios` access token) → 201 `{id, name, scope, token, created_at, expires_at, last_used_at}` (`token` only in this reply) |
| `GET /me/tokens`, `DELETE /me/tokens/{id}` | list (no `token`) / 204 |
| Every other REST route, `/mcp` | unchanged shapes; `Authorization: Bearer <lc_at_ or lc_pat_>`; scoped to that user; 401 `{"detail": "Unauthorized"}` without a valid token |

## Data model (030a)
- `user {id UUID, email, created_at, last_seen_at}`; `identity {provider, subject, user_id, created_at}` with
  primary key `(provider, subject)`; `apitoken {id, user_id, kind: access|refresh|pat, hash, scope, name,
  client_id, family_id, expires_at, created_at, last_used_at, revoked_at}`.
- `user_id` (indexed, not null) on `note`, `card`, `reviewlog`, `report`, `feedback`, `activityevent` (029) and
  `settings` (rebuilt: one row per user, primary key `user_id`).
- Every `deck` function takes `user_id` and filters on it. Another user's id answers like an unknown id (404 /
  `ToolError` "not found"), never 403: existence doesn't leak.

## Migration (030a; the user's deck becomes the first account)
1. Set `LA_CARTE_OWNER_EMAIL=<the user's Google email>` in Dokploy **before** deploying 030a. A pre-030 database
   that holds any data refuses to start without it (clear log line), so the deck can't be orphaned or claimed by
   the wrong person.
2. Startup migration 030 (backup `<db>.pre-030-<timestamp>.bak`, one transaction): create `user` row *owner*
   (email = `LA_CARTE_OWNER_EMAIL`, no identity), add `user_id = owner` to every owned row, rebuild `settings`.
3. If `LA_CARTE_API_TOKEN` is set, it is stored (hashed) as the owner's PAT named `legacy`, scope `deck`, no
   expiry (principle 7). The app,
   widget, Claude Code `--header` and scripts keep working unchanged. Afterwards the variable is ignored (startup
   logs "LA_CARTE_API_TOKEN is imported; remove it from the environment").
4. When 030b is live, the owner's first Google sign-in with the verified `LA_CARTE_OWNER_EMAIL` attaches
   `(google, sub)` to that row (principle 4). From then on, the account is found by `sub`.

## Sign-up gate (030b): optional and silent
`LA_CARTE_ALLOWED_EMAILS` = comma-separated emails (casefolded). **Optional: unset or empty = open sign-up**
(any verified Google account gets a deck). When set, only listed emails (and the owner) can create an account;
checked at every Google sign-in, before any account is created. A refused sign-in creates nothing and ends with
OAuth `access_denied` / `not_allowed`; the app shows only "This account can't be used yet." (030c).
**No user-facing text mentions invites or a list** (user decision 2026-11-26): not the app, not server pages, not
`/privacy`. **Manager: confirm with the user whether to keep the gate at all.** If not, 030b drops the variable,
the `not_allowed` branch and its AC 10, and 030c drops the `.notAllowed` message and AC 3.

## Secrets and env (Dokploy only; nothing secret in the repo)
| Variable | Secret | Note |
|---|---|---|
| `LA_CARTE_GOOGLE_CLIENT_ID` | no | Google "Web application" OAuth client |
| `LA_CARTE_GOOGLE_CLIENT_SECRET` | **yes** | same client |
| `LA_CARTE_PUBLIC_URL` | no | now **required** when Google is configured (issuer, callback, metadata); https |
| `LA_CARTE_OWNER_EMAIL` | personal | before 030a deploys |
| `LA_CARTE_ALLOWED_EMAILS` | personal | optional sign-up allowlist; unset = open sign-up |
| `LA_CARTE_API_TOKEN` | **yes** | imported once as the owner's PAT by 030a, then remove it |
| `LA_CARTE_SUPPORT_EMAIL` | personal | optional; shown on `/privacy` |
| `LA_CARTE_IDENTITY_PROVIDER` | no | `google` (default) or `fake` (tests/e2e only; refused unless `LA_CARTE_PUBLIC_URL` is unset or loopback) |

No token-signing key is needed (principle 5). iOS build setting `LA_CARTE_DEFAULT_API_URL` (030c) is supplied by
CI from a repository **variable**, empty in the repo. It is the **only** server the app talks to: the app has no
server URL field or "use your own server" option (user decision 2026-11-26).

## Self-hosting
Self-hosting stays supported, from source; the App Store app talks only to the hosted server. A self-hoster:
1. Runs the API (`docs/deploy.md`) with their own `LA_CARTE_PUBLIC_URL` (https) and `LA_CARTE_OWNER_EMAIL`.
2. Registers **their own** Google OAuth client ("Web application", authorised redirect URI
   `<their PUBLIC>/oauth/callback`, scopes `openid email`) as in "User actions" 1, and sets
   `LA_CARTE_GOOGLE_CLIENT_ID` / `LA_CARTE_GOOGLE_CLIENT_SECRET` (optionally `LA_CARTE_ALLOWED_EMAILS`).
3. Builds the app from source with `LA_CARTE_DEFAULT_API_URL = https://<their host>` (in
   `ios/Config/Signing.local.xcconfig`, next to their bundle id prefix and team) and installs it on their own
   devices. Agents connect to `<their PUBLIC>/mcp` as usual.

## User actions needed (smallest steps; the manager asks one at a time, before 030b deploys)
1. **Google Cloud Console** (console.cloud.google.com, the user's Google account):
   a. Create a project "la-carte".
   b. Google Auth Platform → Branding: app name "la-carte", support email, privacy policy
      `<PUBLIC>/privacy`, authorised domain = the API's domain.
   c. Audience: External; **Publish app** (in production). With only `openid email` (non-sensitive) no
      verification is required (support.google.com/cloud/answer/13463073); staying in Testing would force adding
      every friend as a Google test user (max 100).
   d. Data access: add `openid` and `.../auth/userinfo.email` only.
   e. Clients → Create client → **Web application**, authorised redirect URI
      `<PUBLIC>/oauth/callback`. Paste the client id and secret into Dokploy (two env vars).
2. **Dokploy env**: `LA_CARTE_OWNER_EMAIL` (before 030a), then `LA_CARTE_GOOGLE_CLIENT_ID`,
   `LA_CARTE_GOOGLE_CLIENT_SECRET`, and `LA_CARTE_ALLOWED_EMAILS` if the gate is kept (before 030b); remove `LA_CARTE_API_TOKEN` after
   030a has started once.
3. **GitHub repository variable** `LA_CARTE_DEFAULT_API_URL` = the API URL (release-engineer wires it into the
   Ad Hoc build, 030c).
4. **Apple**: nothing now (custom URL scheme callback, no associated domains, no new capability).

## App Store note (for the manager to raise with the user before App Store submission)
Verified 2026-11-25 against developer.apple.com/app-store/review/guidelines/#login-services:
- **4.8 Login Services**: an app that uses a third-party login (Google Sign-In is named) "to set up or authenticate
  the user's primary account with the app must also offer as an equivalent option another login service" that
  limits data to name and email, lets the user keep their email private, and doesn't collect interactions for
  ads without consent. None of the exceptions fits (our server holds the account, but the only way in is Google,
  so it isn't "exclusively … your company's own account setup and sign-in"). **So the App Store release needs a
  second, privacy-focused login next to Google, in practice Sign in with Apple**, as visible as the Google button.
  It can go in as a second `IdentityProvider` (native `ASAuthorizationAppleIDProvider` in the app, server verifies
  Apple's identity token; Apple team/key setup; store Apple's refresh token to revoke it on account deletion).
  Backlog item, not now.
- It does **not** block the friends phase: Ad Hoc builds (today's channel, docs/release.md) and internal TestFlight
  have no review. External TestFlight goes through Beta App Review, which applies the guidelines and may raise 4.8.
- **5.1.1(v) account deletion**: in-app, easy to find, deletes the account record and its data (not
  deactivation). Covered now by 030a `DELETE /me` + 030c Settings.
- **5.1.1(i) privacy policy**: a link in App Store Connect and inside the app. Covered by `/privacy` (030b) and the
  Settings / sign-in links (030c).

## App Privacy notes (App Store Connect "App Privacy", for the release-engineer / manager)
Data linked to the user, used for app functionality only, no tracking, no third-party sharing:
- Contact info → **Email address** (the verified Google email; sign-up gate and support).
- Identifiers → **User ID** (our account id; Google's `sub` stored server-side as the account key).
- User content → **Other user content** (cards, notes, reports, feedback).
- Usage data → **Product interaction** (spec 029 activity log, if it ships), app functionality.
Not collected: name, photo, contacts, location, payment, passwords (principle 1, 3). Person-card photos are
external URLs the user (or their agent) typed; la-carte hosts no images.

## Rollout (API first)
1. 030a merged → deploy with `LA_CARTE_OWNER_EMAIL` set (keep `LA_CARTE_API_TOKEN` for this first start).
   Check: the user's app, widget and Claude Code still work; `GET /me` answers the owner. Then remove the token var.
2. 030b merged → user does "User actions" 1–2 → deploy. Check: Claude Code `claude mcp add --transport http
   la-carte <PUBLIC>/mcp` signs in with Google (no `--header`); claude.ai custom connector does the same; if
   the allowlist is set, an unlisted Google account is refused. (Set it, e.g. to the owner's email, before the
   Google vars if sign-up should not be open yet.)
3. 030c (then 030d) merged + QA PASS → Ad Hoc build with the default URL → user signs in on the iPhone (claims nothing new:
   the owner row is already claimed in step 2 or claimed now) → friends' emails added to the allowlist (if
   the gate is kept) → friends install.

## Out of scope (backlog)
- Sign in with Apple (App Store blocker, see note). CIMD client registration. An admin UI or roles beyond the
  owner's MCP access to feedback (decision 10).
  Rate limiting. Email sending of any kind. Linking a second
  provider. Hosting photos. Multiple decks per user. Shared decks.
