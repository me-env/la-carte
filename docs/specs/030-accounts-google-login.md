# 030 — Accounts: sign in with Apple or Google, for the App Store (overview)

Status: ready (overview; the work is in 030a–030h, order below). Updated 2026-11-28 for the App Store launch
(user decisions: Sign in with Apple next to Google, in-app deletion that revokes both grants, a public privacy
policy and landing page on the API's domain, open sign-up as the default so App Review uses its own Apple ID).
Owners: api-engineer (030a → 030b → 030e → 030g; 030h) ∥ ios-engineer (030c → 030f → 030d, on mock) ∥ marketing +
design-lead (030h content and look) ∥ release-engineer (030f entitlement, default-URL build setting) →
code-reviewer → qa-validator
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg (one centered message + one
button, like 008's "Connect your deck"); Apple's HIG "Sign in with Apple" and Google's "Sign in with Google"
branding guidelines for the two buttons.

## Goal
la-carte goes on the App Store. Each person signs in with Apple or Google, gets **their own deck**, can delete their
account and everything in it from the app, and can plug the same server into any agent (Claude, ChatGPT, Cursor, …)
as an MCP connector that signs in the same way. No frontend app: the API is its own OAuth 2.1 authorization server
and delegates identity to Apple or Google. The API also serves a privacy policy, a support page and a one-page
landing site.

## The split
| Spec | What | Lane | Ships |
|---|---|---|---|
| [030a](030a-accounts-api.md) | `user` + `identity` + `apitoken` tables, `user_id` on every owned table, every query scoped, migration (the deck → the owner, the static token → the owner's PAT), bearer verification for REST + `/mcp`, `GET/DELETE /me`, `GET/DELETE /me/tokens`, cross-user tests | `api/**` | Deploy alone: the user's app, widget and agents keep working on the old token (now the owner's PAT) |
| [030b](030b-oauth-google.md) | OAuth 2.1 authorization server (MCP SDK provider): metadata, DCR, `/authorize` → consent → Google → our code → `/token`, refresh rotation, `/revoke`, `POST /me/tokens`, sign-up mode (open default), email-collision rule, fake identity provider | `api/**` after 030a | Deploy with the Google env vars; connect Claude |
| [030c](030c-ios-sign-in.md) | Sign-in screen, `ASWebAuthenticationSession`, Keychain session + refresh, widget token, Settings account section (sign out, delete account, privacy) | `ios/**`; can start with 030a on mock; ships after 030b is deployed | Ad Hoc build for friends |
| [030d](030d-ios-access-tokens.md) | Settings → "Access tokens": create (name, optional expiry), copy once, list, revoke | `SettingsFeature/**` after 030c | With or after 030c; not an App Store blocker |
| [030e](030e-apple-sign-in-api.md) | Sign in with Apple, server: `POST /oauth/apple` (identity token checked against Apple's JWKS, code exchanged, Apple refresh token kept), Apple revoked on `DELETE /me`, Google token revoked right after each sign-in | `api/**` after 030b | With the Apple env vars |
| [030f](030f-apple-sign-in-ios.md) | Sign in with Apple, iOS: native button above Google's, `ASAuthorizationController`, provider shown in Settings; entitlement | `SignInFeature/**`, `APIClient/**` after 030c; `ios/Config` entitlement (release-engineer) | After 030e is deployed |
| [030g](030g-apple-sign-in-web.md) | "Continue with Apple" on the agents' consent page (web flow, Services ID, form_post callback) | `api/**` after 030e | After 030e; not an App Store blocker |
| [030h](030h-web-landing-privacy.md) | Landing page `/`, `/privacy`, `/support`, static files served by the API | `api/src/la_carte_api/site/**` + `app.py` routes; marketing media, design-lead note | Any time; **first**, since the Google client's branding needs the privacy URL |

Deletion (5.1.1(v)) is not a part of its own: `DELETE /me` and its data scope are 030a, the provider revocation is
030e, the Settings button and confirmation are 030c.

### Order and parallelism
```
api lane (one at a time):   030h ─► 030a ─► 030b ─► 030e ─► 030g
                            (030h is small and can also run in its own worktree next to 030a)
iOS lane (one at a time):   030c ─► 030f ─► 030d          (on mock, in parallel with the api lane)
release-engineer:           030f entitlement + default-URL build setting (any time)
marketing ∥ design-lead:    030h copy + media ∥ 030h design note (now)
```
App Store blockers: 030a, 030b, 030c, 030e, 030f, 030h, and 032a (encryption at rest, built on `accounts`).
Not blockers: 030d, 030g.
Deploy: 030h can merge to main and deploy now (no migration). 030a onward stays on the accounts branch until the
Dokploy env is set (see "What the user provides").

## Principles (also in `docs/architecture.md`)
1. **Never passwords.** la-carte stores no passwords or password hashes, and offers no password login, password
   reset or "magic link". Ever. Identity is always OAuth/OpenID Connect with an external provider.
2. **Two identity providers: Apple and Google** (guideline 4.8), behind one boundary (`identity.py`). Google goes
   through our `/authorize` and a browser sheet (030b); Apple in the app is native (`ASAuthorizationController` →
   `POST /oauth/apple`, 030e/030f) and on the agents' consent page a web flow (030g). Both end in the same account
   resolution and the same la-carte tokens.
3. **Take the minimum (data minimisation).** Google: scopes `openid email` only (no `profile`: no name, no
   picture). Apple: scope `email` only (no name). We store the provider's `sub` (the account key) and the
   **verified** email (sign-up allowlist mode, support); Apple's Hide My Email relay address is stored like any
   email (we never send email). An unverified email is refused. We keep no Google token: Google's code is
   exchanged once, the ID token read, the access token **revoked** and dropped, so no Google grant outlives a
   sign-in. From Apple we keep only its refresh token, solely to revoke Sign in with Apple on deletion (030e).
4. **One account per provider identity; never merged by email.** An account is found by (provider, `sub`). Apple and
   Google identities are **not linked**: each account has exactly one identity. Email-collision rule (the simplest
   safe one): a new identity whose verified email already belongs to another account is **refused**, with nothing
   written, and told which provider to use (`use_google` / `use_apple`; same provider with another `sub`:
   `email_in_use`). No auto-merge means no account takeover through a provider's email claim; telling the provider
   only reveals it to someone who just proved they own that email. A Hide My Email relay address never collides,
   so someone who used Google first and then Apple with a hidden email gets a second, empty account: acceptable
   (explicit linking is backlog). The one email-based attach is claiming the owner row that migration 030 creates
   *without* an identity: the first verified sign-in (either provider) with exactly `LA_CARTE_OWNER_EMAIL`.
5. **All tokens are ours, opaque, and stored hashed.** Access, refresh and personal access tokens are random
   256-bit strings minted by la-carte (prefixes `lc_at_`, `lc_rt_`, `lc_pat_`); the database stores only their
   SHA-256. Opaque tokens mean **no token-signing key** to manage: revocation is a row update.
6. **OAuth is the primary path; personal access tokens (PATs) are the secondary one.** Agents connect with OAuth
   (030b). PATs stay for scripts, CI/e2e and MCP clients without OAuth (`Authorization: Bearer lc_pat_…`). They are
   API tokens, **not passwords**: minted only by a signed-in user (Apple or Google), **from the app** (`POST /me/tokens`
   accepts only an access token issued to the `la-carte-ios` client; a PAT or an agent's token can't mint one),
   scoped to that user, shown once, stored hashed, revocable, with an optional expiry. The app also mints one
   `stats`-scoped PAT for its widget. e2e gets its PAT the same way: a fake-provider sign-in as `la-carte-ios`, then
   `POST /me/tokens`.
7. **The legacy static token (`LA_CARTE_API_TOKEN`) is migrated to a PAT, not kept as a mode.** Migration 030
   stores it (hashed) as the owner's PAT `legacy`, then the variable is ignored. Why: one auth path to build, test
   and secure (every request resolves to a user through `apitoken`), the user's devices and agents keep working
   with zero change, and the owner can revoke it like any PAT. A "single-user self-host mode" would be a second
   code path (no users, unscoped queries) that every future feature must keep working. Self-hosters run the same
   server with their own Google client (and optionally Apple key) and `LA_CARTE_OWNER_EMAIL`.
8. **No token passthrough.** Apple's and Google's tokens never reach `/mcp` or REST, and our tokens never go to them
   (MCP authorization spec 2026-07-28, "Token passthrough" is forbidden).
9. **The API stays the single source of truth** and holds all auth logic. The only HTML it serves: the consent
   page for agent connectors, sign-in error pages, and the static site of 030h (`/`, `/privacy`, `/support`). No
   web app.
10. **Everyone sees only their own data, except the owner reads feedback** (user decision 2026-11-26). The owner
   (the `user` whose email equals `LA_CARTE_OWNER_EMAIL`; nobody when unset) gets, **over MCP only**: every user's
   feedback in `list_feedback` (each item carries its sender's `user_email`), `close_feedback` on any of it, and
   `activity_log(user=<email>)` for a user who has sent at least one feedback, scoped to that user. Nothing else is
   cross-user (deck, reviews, reports, stats, tokens), no admin UI, no REST route, no role table. `/privacy` says
   so (030h). Detail and tests in 030a.
11. **Deletion is complete and immediate** (5.1.1(v)). `DELETE /me` first revokes Sign in with Apple (best effort:
   an Apple outage never keeps the data), then deletes in one transaction the user's notes, cards, reviews,
   reports, feedback, activity events, settings, tokens, identities and the user row. Server backups age out within
   30 days (stated in `/privacy`). The app also deletes its local session, widget token and activity buffer.
12. **Encryption at rest, always on** ([032](032-encryption.md)). The whole database is encrypted with a server key
   (SQLCipher, `LA_CARTE_DB_KEY`): a stolen file or backup is unreadable. The operator and the running server can
   read the data, as they must to serve the app and agents. Not end-to-end. A per-user key was rejected (backlog
   #72).

## The flow (Google, and Apple on the web for agents; Apple in the app is native, 030e/030f)
```
client (iOS app | Claude | ChatGPT | Cursor …)
  │ 1 GET /authorize?client_id&redirect_uri&code_challenge(S256)&state&scope=deck&resource=<PUBLIC>/mcp
  ▼
la-carte /authorize ── stores the pending request ──► agent clients: /oauth/consent (one click) ─┐
  │                                                     iOS client (built in): straight on ──────┤
  ▼                                                                                               ▼
accounts.google.com (scope "openid email", our state + nonce + PKCE, prompt=select_account)
  | or appleid.apple.com (agents only, 030g: scope "email", response_mode=form_post)
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
| `POST /oauth/apple` (form) | `client_id=la-carte-ios`, `identity_token`, `authorization_code`, `nonce` (raw) → the `/token` body; errors 400 `{error, error_description}`: `access_denied` + `not_allowed` \| `use_google`, `invalid_grant` + `sign_in_failed` (030e) |
| `POST /revoke` (form) | `token`, `client_id` → 200 |
| `GET /me` | `{id, email, provider: "apple" \| "google" \| null, created_at}` |
| `DELETE /me` | 204; Apple revoked (best effort), the account and everything it owns are gone |
| `POST /me/tokens` | `{name, scope: "deck" \| "stats", expires_in_days?: 1–365}` (only with an `la-carte-ios` access token) → 201 `{id, name, scope, token, created_at, expires_at, last_used_at}` (`token` only in this reply) |
| `GET /me/tokens`, `DELETE /me/tokens/{id}` | list (no `token`) / 204 |
| Every other REST route, `/mcp` | unchanged shapes; `Authorization: Bearer <lc_at_ or lc_pat_>`; scoped to that user; 401 `{"detail": "Unauthorized"}` without a valid token |

## Data model (030a)
- `user {id UUID, email, created_at, last_seen_at}`; `identity {provider, subject, user_id, created_at,
  provider_token, provider_client_id}` with primary key `(provider, subject)` (`provider_token`: Apple's refresh
  token only); `apitoken {id, user_id, kind: access|refresh|pat, hash, scope, name,
  client_id, family_id, expires_at, created_at, last_used_at, revoked_at}`.
- `user_id` (indexed, not null) on `note`, `card`, `reviewlog`, `report`, `feedback`, `activityevent` (029) and
  `settings` (rebuilt: one row per user, primary key `user_id`).
- Every `deck` function takes `user_id` and filters on it. Another user's id answers like an unknown id (404 /
  `ToolError` "not found"), never 403: existence doesn't leak.

## Migration (030a; the user's deck becomes the first account)
1. Set `LA_CARTE_OWNER_EMAIL=<the user's Apple or Google email>` in Dokploy **before** deploying 030a. A pre-030 database
   that holds any data refuses to start without it (clear log line), so the deck can't be orphaned or claimed by
   the wrong person.
2. Startup migration 030 (backup `<db>.pre-030-<timestamp>.bak`, one transaction): create `user` row *owner*
   (email = `LA_CARTE_OWNER_EMAIL`, no identity), add `user_id = owner` to every owned row, rebuild `settings`.
3. If `LA_CARTE_API_TOKEN` is set, it is stored (hashed) as the owner's PAT named `legacy`, scope `deck`, no
   expiry (principle 7). The app,
   widget, Claude Code `--header` and scripts keep working unchanged. Afterwards the variable is ignored (startup
   logs "LA_CARTE_API_TOKEN is imported; remove it from the environment").
4. When 030b (or 030e) is live, the owner's first sign-in with the verified `LA_CARTE_OWNER_EMAIL` attaches
   `(google|apple, sub)` to that row (principle 4). From then on, the account is found by `sub`. (The owner must use
   a provider that shares the real email: Apple with Hide My Email would create a new, empty account.)

## Sign-up mode (030b): a server setting, open by default
`LA_CARTE_SIGNUP` = `open` (**default**: any verified Apple or Google account gets a deck) or `allowlist` (only
`LA_CARTE_ALLOWED_EMAILS`, comma-separated, casefolded, plus the owner can create an account; checked at every
sign-in, before anything is created). A refused sign-in creates nothing and ends with OAuth `access_denied` /
`not_allowed`; the app shows only "This account can't be used yet." (030c).
**The App Store build needs `open`** (user decision 2026-11-28): App Review signs in with its own Apple ID, often
behind Hide My Email, so no allowlist can name it in advance, and no demo account is provided. `allowlist` stays
for self-hosters and for a private phase. **No user-facing text mentions invites or a list** (user decision
2026-11-26): not the app, not server pages, not `/privacy`.

## Secrets and env (Dokploy only; nothing secret in the repo)
| Variable | Secret | Note |
|---|---|---|
| `LA_CARTE_GOOGLE_CLIENT_ID` | no | Google "Web application" OAuth client |
| `LA_CARTE_GOOGLE_CLIENT_SECRET` | **yes** | same client |
| `LA_CARTE_PUBLIC_URL` | no | now **required** when Google is configured (issuer, callback, metadata); https |
| `LA_CARTE_OWNER_EMAIL` | personal | before 030a deploys |
| `LA_CARTE_SIGNUP` | no | `open` (default) or `allowlist` |
| `LA_CARTE_ALLOWED_EMAILS` | personal | read only when `LA_CARTE_SIGNUP=allowlist` |
| `LA_CARTE_API_TOKEN` | **yes** | imported once as the owner's PAT by 030a, then remove it |
| `LA_CARTE_APPLE_TEAM_ID` | no | 030e; the four Apple variables turn Apple on together |
| `LA_CARTE_APPLE_KEY_ID` | no | 030e; the Sign in with Apple key's id |
| `LA_CARTE_APPLE_PRIVATE_KEY_B64` | **yes** | 030e; the `.p8` file, base64 on one line |
| `LA_CARTE_APPLE_BUNDLE_ID` | no | 030e; the app's bundle id (`aud` of native identity tokens) |
| `LA_CARTE_APPLE_SERVICES_ID` | no | 030g; optional, turns on Apple on the agents' consent page |
| `LA_CARTE_SUPPORT_EMAIL` | personal | 030h; shown on `/privacy` and `/support` (lines omitted when unset) |
| `LA_CARTE_OPERATOR_NAME` | personal | 030h; who runs the service, in `/privacy` (default "the developer of la-carte") |
| `LA_CARTE_APP_STORE_URL` | no | 030h; the landing's App Store badge (unset: "Coming soon") |
| `LA_CARTE_DB_KEY` | **yes** | 032a; 64 hex, the database's SQLCipher key; required in production; keep a copy offline |
| `LA_CARTE_IDENTITY_PROVIDER` | no | `google` (default) or `fake` (tests/e2e only; refused unless `LA_CARTE_PUBLIC_URL` is unset or loopback) |

No token-signing key of ours is needed (principle 5); the Apple key only signs Apple's `client_secret` (030e). iOS build setting `LA_CARTE_DEFAULT_API_URL` (030c) is supplied by
CI from a repository **variable**, empty in the repo. It is the **only** server the app talks to: the app has no
server URL field or "use your own server" option (user decision 2026-11-26).

## Self-hosting
Self-hosting stays supported, from source; the App Store app talks only to the hosted server. A self-hoster:
1. Runs the API (`docs/deploy.md`) with their own `LA_CARTE_PUBLIC_URL` (https) and `LA_CARTE_OWNER_EMAIL`.
2. Registers **their own** Google OAuth client ("Web application", authorised redirect URI
   `<their PUBLIC>/oauth/callback`, scopes `openid email`) as in "What the user provides" 3, and sets
   `LA_CARTE_GOOGLE_CLIENT_ID` / `LA_CARTE_GOOGLE_CLIENT_SECRET` (optionally `LA_CARTE_SIGNUP=allowlist` +
   `LA_CARTE_ALLOWED_EMAILS`). Apple is optional for a self-hoster (their own Apple team, key and bundle id).
3. Builds the app from source with `LA_CARTE_DEFAULT_API_URL = https://<their host>` (in
   `ios/Config/Signing.local.xcconfig`, next to their bundle id prefix and team) and installs it on their own
   devices. Agents connect to `<their PUBLIC>/mcp` as usual.

## What the user provides (one list; the manager asks once, then each item lands where noted)
Nothing here goes in the repo. Values go to Dokploy env (the La Carte project only) or a GitHub repository variable.

1. **Support email** (a public contact address): `LA_CARTE_SUPPORT_EMAIL` in Dokploy; also the Google branding
   support email, the App Store support contact and TestFlight feedback email. Optionally the **operator name** for
   the privacy policy (`LA_CARTE_OPERATOR_NAME`; a trade name is fine).
2. **Approve the privacy policy text** (030h "Privacy policy text"), and keep Dokploy volume backups at **30 days or
   less** (the policy says so; Dokploy → the compose service → Volume Backups → keep the latest 30).
3. **Google OAuth client** (console.cloud.google.com, the user's Google account), after 030h is deployed:
   a. Create a project "la-carte".
   b. Google Auth Platform → Branding: app name "la-carte", support email (item 1), privacy policy
      `<PUBLIC>/privacy`, home page `<PUBLIC>/`, authorised domain = the API's domain.
   c. Audience: External; **Publish app** (in production). With only `openid email` (non-sensitive) no
      verification is required (support.google.com/cloud/answer/13463073).
   d. Data access: add `openid` and `.../auth/userinfo.email` only.
   e. Clients → Create client → **Web application**, authorised redirect URI `<PUBLIC>/oauth/callback`.
   → `LA_CARTE_GOOGLE_CLIENT_ID`, `LA_CARTE_GOOGLE_CLIENT_SECRET` in Dokploy.
4. **Apple Developer** (developer.apple.com → Certificates, Identifiers & Profiles; Account Holder or Admin):
   a. Identifiers → the app's App ID → Capabilities → **Sign in with Apple** → "Enable as a primary App ID" → Save
      (skip if release-engineer's automatic signing already added it; existing profiles are regenerated by it).
   b. Keys → + → name "la-carte sign in", check **Sign in with Apple** → Configure → primary App ID = the app →
      Register → **download the `.p8` once** and note the Key ID.
   → `LA_CARTE_APPLE_TEAM_ID`, `LA_CARTE_APPLE_KEY_ID`, `LA_CARTE_APPLE_PRIVATE_KEY_B64`
     (`base64 -i AuthKey_<KEYID>.p8 | tr -d '\n'`), `LA_CARTE_APPLE_BUNDLE_ID` (the app's bundle id) in Dokploy.
   c. Only for 030g (Apple on the agents' consent page; can come later): Identifiers → + → **Services IDs** →
      identifier e.g. `<bundle id>.web` → enable Sign in with Apple → Configure: primary App ID = the app (so web and
      app give the same user id), domain = the API's domain, return URL `<PUBLIC>/oauth/callback`.
      → `LA_CARTE_APPLE_SERVICES_ID` in Dokploy.
5. **Dokploy env for the accounts deploy** (with the values above): `LA_CARTE_OWNER_EMAIL` (the email of the
   user's own Apple or Google account that should own today's deck), `LA_CARTE_PUBLIC_URL` (the https URL, if not
   set yet). `LA_CARTE_SIGNUP` stays unset (= open). Remove `LA_CARTE_API_TOKEN` after 030a has started once.
6. **GitHub repository variable** `LA_CARTE_DEFAULT_API_URL` = the API URL (release-engineer wires it into the
   builds, 030c).
7. Later, when the app is live: `LA_CARTE_APP_STORE_URL` in Dokploy. App Store Connect itself is the user's job
   (`docs/release-app-store.md`).

## App Store notes
Checked 2026-11-25 against developer.apple.com/app-store/review/guidelines; decisions 2026-11-28:
- **4.8 Login Services**: a Google login must come with an equivalent privacy-focused option → **Sign in with
  Apple** (030e/030f), its button as prominent as Google's (above it, same size: 030c design note).
- **5.1.1(v) account deletion**: in the app, easy to find, real deletion (not deactivation), Sign in with Apple
  tokens revoked through Apple's REST API → 030a + 030c + 030e (principle 11).
- **5.1.1(i) privacy policy**: in App Store Connect and inside the app → `/privacy` (030h), linked from the sign-in
  screen and Settings (030c).
- **2.1 review access**: open sign-up (default) + Sign in with Apple, so the reviewer signs in with their own Apple
  ID and gets an empty deck; the review notes say so and explain how to add a first card. No demo account.

## App Privacy notes (App Store Connect "App Privacy"; must match `ios/LaCarte/PrivacyInfo.xcprivacy` and `/privacy`)
Data linked to the user, used for app functionality only, no tracking, no third-party sharing:
- Contact info → **Email address** (from Apple, possibly a Hide My Email relay, or Google).
- Identifiers → **User ID** (our account id; Apple's or Google's `sub` stored server-side as the account key).
- User content → **Other user content** (notes, cards, reports, feedback).
- Usage data → **Product interaction** (spec 029 activity log).
- Diagnostics → **Other diagnostic data** (activity errors, app and OS version).
Not collected: name, photo, contacts, location, payment, passwords (principles 1, 3). Encryption at rest (032) changes no answer: content
is still stored and processed on our server, so it is "collected"; we never claim end-to-end encryption. Person-card photos are
external URLs the user (or their agent) typed; la-carte hosts no images.

## Rollout (API first)
1. 030h merged → deploy (no migration). Check `<PUBLIC>/`, `/privacy`, `/support`. Then the user can do "What the
   user provides" 3 (Google branding needs the privacy URL).
2. 030a + 030b (+ 030e) on the accounts branch, reviewed and QA'd → the user sets items 1–5 in Dokploy → merge and
   deploy (keep `LA_CARTE_API_TOKEN` for this first start). Check: the user's app, widget and Claude Code still
   work; `GET /me` answers the owner; Claude Code `claude mcp add --transport http la-carte <PUBLIC>/mcp` signs in
   with Google. Then remove the token var.
3. 030c + 030f (then 030d) merged + QA PASS → build with the default URL → the user signs in on the iPhone with the
   owner's provider and sees their deck; a second Apple ID with Hide My Email gets an empty deck; Delete Account
   on that test account revokes it (030e AC 13).
4. 030g whenever convenient (after item 4c).
5. App Store Connect: the user, from `docs/release-app-store.md`.

## Out of scope (backlog)
- Linking Apple and Google on one account. Apple server-to-server notifications and launch-time credential-state
  checks. CIMD client registration. An admin UI or roles beyond the owner's MCP access to feedback (decision 10).
  Rate limiting (needed before App Store with open sign-up: backlog #61). Email sending of any kind. Hosting photos.
  Multiple decks per user. Shared decks. Starter cards for a new account.
