# 030b — Sign in with Google: la-carte as an OAuth 2.1 authorization server (API + MCP)

Status: ready
Owners: api-engineer → code-reviewer → qa-validator (pytest + a manual Claude connector check with the user)
Depends on: 030a merged. Overview, principles, flow diagram, env and user actions: [030](030-accounts-google-login.md).
Design reference: none for the app. The consent and error pages are plain server HTML (system font, the
la-carte icon from `/icon.svg`, one heading, one sentence, one button; light/dark via `prefers-color-scheme`).

## Goal
Any MCP client (Claude Code, claude.ai connectors, ChatGPT, Cursor, VS Code) and the iOS app can sign the user in
with Google against the API itself, and receive la-carte tokens scoped to that user's deck. Sign-up is open by
default; a server setting can switch it to a silent allowlist (030 "Sign-up mode").

## User stories
- As the user, I run `claude mcp add --transport http la-carte https://<api>/mcp`, a browser opens, I pick my
  Google account, and Claude can use my deck. No token to copy.
- As the user, I add the same URL as a custom connector on claude.ai and it works the same way.
- As someone the allowlist refuses (only when the server runs in `allowlist` mode), my client gets a neutral `access_denied` (no mention of invites) and
  no account is created.
- As the app, I sign the user in through the same endpoints (030c).

## Verified ground (2026-11-25)
- MCP authorization spec, revision 2026-07-28: protected resource metadata (RFC 9728) MUST; authorization server
  metadata (RFC 8414); PKCE S256 MUST; `resource` (RFC 8707) sent by clients and the audience checked; token
  passthrough forbidden; registration priority pre-registered → CIMD (SHOULD) → DCR (MAY, deprecated, kept ≥ 12
  months); public-client refresh tokens rotated; RFC 9207 `iss` on the authorization response (SHOULD).
- `mcp` 2.3.0 (`mcp/server/auth/`): `OAuthAuthorizationServerProvider` (`get_client`, `register_client`,
  `authorize → redirect URL`, `load_authorization_code`, `exchange_authorization_code`, `load_refresh_token`,
  `exchange_refresh_token`, `load_access_token`, `revoke_token`), `create_auth_routes` (`/authorize`, `/token`,
  `/register`, `/revoke`, `/.well-known/oauth-authorization-server`), protected resource routes at
  `/.well-known/oauth-protected-resource/mcp`, `RequireAuthMiddleware`, `get_access_token()`. Mounted at `/`
  under FastAPI, these land at the root. Gaps we fill: its AS metadata omits `"none"` from
  `token_endpoint_auth_methods_supported` and the `iss` flag (we serve our own metadata route, registered in
  FastAPI before the mount so it wins); the token handler checks the stored code's or refresh token's `client_id`
  but not `resource` (we check it, decision 7); its `/revoke` requires a `client_secret` (we serve our own,
  decision 7); no CIMD. *(Corrected in implementation 2026-11-28: this line first said `client_id` was unchecked
  too.)*
- Clients: claude.ai (DCR or CIMD; redirect `https://claude.ai/api/mcp/auth_callback`; needs the 401
  `resource_metadata`; PRM `resource` must equal the URL typed; 10 s timeouts), Claude Code (loopback callback on a
  random port; CIMD then DCR; `--header` still works for PATs), ChatGPT (CIMD/DCR; S256 required; wants `iss`),
  Cursor (DCR), VS Code (pre-registered id or headers). **DCR is the one method all support → we do DCR now.**
- Google: "Web application" client (the OAuth client is our server), redirect URI exact and https; ID token
  received straight from Google's token endpoint over TLS (OIDC Core 3.1.3.7: TLS server validation may replace the
  signature check); check `iss` ∈ {`https://accounts.google.com`, `accounts.google.com`}, `aud` = our client id,
  `exp`, `nonce`, `email_verified`; key the account on `sub`. `openid email` are non-sensitive: no verification.

## Decisions
1. **Wiring**: `build_mcp` gets `auth=AuthSettings(issuer_url=<PUBLIC>, resource_server_url=<PUBLIC>/mcp,
   required_scopes=["deck"], client_registration_options=ClientRegistrationOptions(enabled=True,
   valid_scopes=["deck"], default_scopes=["deck"]), revocation_options=RevocationOptions(enabled=True))` and
   `auth_server_provider=LaCarteOAuth(...)` (new `oauth.py`). `LaCarteOAuth.load_access_token` uses 030a's
   `auth.verify`, so PATs keep working on `/mcp`. Our own routes (FastAPI, before the mount):
   `GET /.well-known/oauth-authorization-server` (SDK fields + `token_endpoint_auth_methods_supported:
   ["none", "client_secret_post", "client_secret_basic"]`, `authorization_response_iss_parameter_supported: true`,
   `code_challenge_methods_supported: ["S256"]`, `scopes_supported: ["deck"]`), the same PRM document also at the
   root `/.well-known/oauth-protected-resource`, `GET/POST /oauth/consent`, `GET /oauth/callback`,
   and in fake mode `GET /oauth/fake/authorize` (`/privacy` is 030h's). All of these, plus `/authorize`, `/token`,
   `/register`, `/revoke`, are public paths. The 401 on `/mcp` adds `scope="deck"`.
2. **Clients** (`oauthclient {client_id pk, info JSON (OAuthClientInformationFull), created_at}`):
   - Built in, never stored: `la-carte-ios`, public (`none`), redirect URIs exactly `lacarte://oauth`.
   - DCR via the SDK's `/register`: public or confidential, stored as sent. Redirect URIs must be `https://` or
     loopback `http://127.0.0.1|localhost|[::1]`; for loopback URIs the port is ignored when matching (RFC 8252
     §7.3), everything else matches exactly.
3. **`authorize(client, params)`** stores a pending request `authrequest {id = random 256-bit state, client_id,
   redirect_uri, redirect_uri_provided_explicitly, code_challenge, scopes, resource, client_state, provider, nonce,
   provider_verifier, created_at}` (10 min TTL; expired rows pruned on insert). `resource`, if sent, must be
   `<PUBLIC>/mcp` or `<PUBLIC>` (else `invalid_target`); absent → `<PUBLIC>/mcp`. It returns:
   - for `la-carte-ios`: the identity provider's URL directly;
   - for every other client: `<PUBLIC>/oauth/consent?request=<id>`, and sets cookie `lc_auth=<id>` (HttpOnly,
     Secure unless loopback, SameSite=Lax, Path=/oauth, 10 min) — the response of `/authorize` is the redirect, so
     the cookie is set on it.
4. **Consent page** (confused-deputy guard required by the MCP security best practices for a proxy with a static
   upstream client id and DCR): "**<client_name>** wants to use your la-carte deck. After you sign in, you'll
   return to **<redirect host>**." Button "Continue with Google" (`POST /oauth/consent`, form field
   `request`; 030g adds "Continue with Apple" and a `provider` field). The POST requires the `lc_auth` cookie to equal `request` (a cross-site auto-submitted form doesn't
   carry a Lax cookie), then 303 → Google. `client_name` is HTML-escaped and shown as untrusted text; the redirect
   host is the trusted part. Shown every time (no remembered consent).
5. **Identity provider boundary** (`identity.py`):
   ```python
   class IdentityProvider(Protocol):
       name: str  # "google" | "fake"
       def authorization_url(self, *, state: str, nonce: str, code_challenge: str) -> str: ...
       async def verify(self, *, code: str, code_verifier: str, nonce: str) -> VerifiedIdentity: ...
   @dataclass(frozen=True)
   class VerifiedIdentity: provider: str; subject: str; email: str  # email verified, casefolded
   ```
   - `GoogleProvider`: `https://accounts.google.com/o/oauth2/v2/auth` with `response_type=code`,
     `scope=openid email`, `redirect_uri=<PUBLIC>/oauth/callback`, `state`, `nonce`, PKCE S256,
     `prompt=select_account`. `verify` posts to `https://oauth2.googleapis.com/token` (client id + secret, code,
     verifier) with `httpx` (moves to runtime deps; transport injectable for tests), decodes the ID token payload
     (TLS-validated, no JWKS), checks `iss`, `aud`, `exp`, `nonce`, `email_verified is True`, then revokes
     Google's access token at `https://oauth2.googleapis.com/revoke` (best effort, 030e decision 7) and
     **discards** it: no Google grant outlives a sign-in. Failure → `IdentityError(reason)`.
   - `FakeProvider` (`LA_CARTE_IDENTITY_PROVIDER=fake`; refused at startup unless `LA_CARTE_PUBLIC_URL` is unset or
     loopback): `authorization_url` → `<PUBLIC>/oauth/fake/authorize?state&nonce`, which immediately redirects to
     `/oauth/callback?code=<email>&state` using `LA_CARTE_FAKE_EMAIL` (or `login_hint` if the client
     passed one through). `verify` returns `("fake", "fake-" + email, email)`; an email starting with `unverified`
     raises the unverified error. CI and e2e never call Google.
   - One callback, `/oauth/callback`, for every provider: the pending request records which provider it went to
     (`authrequest.provider`), so a second provider adds a class, not a route.
6. **Callback** `GET /oauth/callback?code&state` (or `error`):
   - Unknown/expired `state` → HTML error page "This sign-in expired. Start again from your app." (400). No
     redirect (we can't trust where to send it).
   - **Agent clients** (any client but `la-carte-ios`): the `lc_auth` cookie is **required** and must equal `state`;
     missing or different → the same 400 page (confused-deputy fix, decided in implementation 2026-11-28: else an
     attacker could send a victim the provider URL of the attacker's own request). The **iOS client** skips consent,
     so it never gets the cookie: its callback ignores `lc_auth` (a stale cookie from an abandoned agent sign-in in
     the same browser must not break it).
   - Google `error` (user cancelled) or `IdentityError` → redirect to the client's `redirect_uri` with
     `error=access_denied` (+ `error_description=cancelled|unverified_email|sign_in_failed`), `state`, `iss`.
   - Account (principle 4 of 030): find `identity (provider, subject)` → its user (update `email`, `last_seen_at`).
     Else, if the email equals `LA_CARTE_OWNER_EMAIL` and that user has no identity → attach. Else, if another
     account already has this email → refuse (no row written): `access_denied` with `error_description` `use_apple`
     when that account signs in with Apple, `use_google` when with Google (030e's Apple path), `email_in_use` when
     it is the same provider with another `sub` (030 principle 4: never merge by email). Else, if `LA_CARTE_SIGNUP`
     is `open` (the default) or the email is allowlisted (`LA_CARTE_ALLOWED_EMAILS` ∪ owner) → create user +
     identity. Else → no row is written; redirect with
     `error=access_denied&error_description=not_allowed`. With an allowlist set, an existing account whose email is
     no longer listed is refused the same way (existing tokens keep working until revoked or the account is
     deleted). No user-facing text anywhere mentions invites or a list. A known identity whose new email would
     collide with another account keeps its stored email. This resolution is one function shared by every
     provider (030e, 030g).
   - Success → mint `authcode {hash, user_id, client_id, redirect_uri, redirect_uri_provided_explicitly,
     code_challenge, scopes, resource, expires_at = now + 5 min}`, delete the pending request, clear `lc_auth`,
     302 → `redirect_uri?code=<lc_ac_…>&state=<client_state>&iss=<PUBLIC>`.
7. **`/token`** (SDK handler + provider):
   - `authorization_code`: code single use (deleted on load), not expired, same `client_id`; `resource` if sent
     equals the code's; PKCE and `redirect_uri` checked by the SDK. Issues `lc_at_` (1 h) + `lc_rt_` (new
     `family_id`; idle lifetime 90 days) with the code's `scope`, `client_id`, user. Response
     `{access_token, token_type: "Bearer", expires_in: 3600, refresh_token, scope}`.
   - `refresh_token`: the token must be live, same `client_id`. It is rotated: marked revoked, a new refresh token
     in the same family + a new access token. **Reuse** of an already-rotated refresh token revokes the whole family
     (its refresh and access tokens) → `invalid_grant`. Expired/revoked/unknown → `invalid_grant`. Requested scopes
     must be a subset.
   - `/revoke`: revoking a refresh token revokes its family; an access token just itself; unknown → 200. **We serve
     `/revoke` ourselves**: mcp 2.3.0's handler requires a `client_secret` field, which public clients don't have.
     A token of another client → 200, nothing done.
   - **We shadow the SDK's `/authorize` and `/token`** (our routes, registered before the MCP mount) to add what the
     SDK lacks: on `/authorize`, the `lc_auth` cookie (decision 3) and RFC 9207 `iss` on error redirects; on
     `/token`, the `resource` check. The SDK still validates the rest (PKCE, `redirect_uri`, client auth).
8. **`POST /me/tokens`** `{name (1–60 chars, trimmed), scope: "deck"|"stats" (default "deck"),
   expires_in_days?: 1–365}` → 201 `{id, name, scope, token, created_at, expires_at, last_used_at: null}`.
   Allowed **only** with an access token whose `client_id` is `la-carte-ios` (a PAT or an agent's access token →
   403 `{"detail": "Create access tokens from the la-carte app"}`; a refresh token is not a bearer credential at
   all → 401, like any unknown token). Max 20 live PATs per user (422).
9. **`/privacy`**: moved to [030h](030h-web-landing-privacy.md) (with the landing and support pages).
10. **Config**: `LA_CARTE_GOOGLE_CLIENT_ID`, `LA_CARTE_GOOGLE_CLIENT_SECRET`, `LA_CARTE_SIGNUP` (`open` default |
    `allowlist`; any other value → refuse to start), `LA_CARTE_ALLOWED_EMAILS` (read only in `allowlist` mode; empty
    = the owner only), `LA_CARTE_IDENTITY_PROVIDER`, `LA_CARTE_FAKE_EMAIL`. Google provider without client
    id/secret, or with an `http://` non-loopback `LA_CARTE_PUBLIC_URL` → refuse to start with a clear message. With
    no provider configured (no Google id, not fake) the server runs PAT-only (sign-in routes answer
    `temporarily_unavailable`), so 030b can deploy before the user has created the Google client.
11. **MCP docs**: architecture's "Connect an agent" becomes `claude mcp add --transport http la-carte <PUBLIC>/mcp`
    (OAuth); `--header "Authorization: Bearer lc_pat_…"` documented as the PAT alternative. Server `instructions`
    unchanged.
12. **Access log without query strings** (review fix on `accounts`, 2026-11-28): a filter on `uvicorn.access`
    (`app.strip_query`) logs the path without its query, because queries carry OAuth codes and `state`
    (`/oauth/callback`) and search terms (`/notes?query=`), which `/privacy` says aren't logged (pytest
    `test_the_access_log_has_no_query_strings`).

## Acceptance criteria
All with the fake provider or an injected `httpx` transport: no test calls Google.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `GET /.well-known/oauth-protected-resource/mcp` and `/.well-known/oauth-protected-resource` return `{resource: "<PUBLIC>/mcp", authorization_servers: ["<PUBLIC>"], scopes_supported: ["deck"], …}`; `/mcp` without a token → 401 with `resource_metadata="<PUBLIC>/.well-known/oauth-protected-resource/mcp"` and `scope="deck"` | pytest |
| 2 | `GET /.well-known/oauth-authorization-server` has `issuer` = `<PUBLIC>` exactly, the four endpoints, `"none"` in `token_endpoint_auth_methods_supported`, `["S256"]`, `authorization_response_iss_parameter_supported: true` | pytest |
| 3 | DCR: `POST /register` with a public client (`token_endpoint_auth_method: "none"`, redirect `http://127.0.0.1:33418/callback`) → 201 with a `client_id`; a redirect `http://evil.example/cb` → 400 | pytest |
| 4 | Full agent flow (fake provider, allowlisted email): `/authorize` (S256, `resource=<PUBLIC>/mcp`) → 302 consent with `lc_auth` cookie → consent page shows the redirect host → POST consent → fake → callback → 302 to the redirect URI (other loopback port accepted) with `code`, the client's `state`, `iss` → `/token` → tokens; the access token lists tools on `/mcp` and reads that user's deck | pytest |
| 5 | iOS flow: `client_id=la-carte-ios`, `redirect_uri=lacarte://oauth` skips consent and ends at `lacarte://oauth?code&state&iss`; `/token` without `client_secret` works; another `redirect_uri` → error, no redirect | pytest |
| 6 | `POST /oauth/consent` without the `lc_auth` cookie, or with a different one → 400, no redirect to the provider | pytest |
| 7 | Wrong `code_verifier`, a reused code, a code older than 5 min, a code presented by another `client_id`, a `resource` different from the code's → `invalid_grant` / `invalid_target`; no tokens | pytest |
| 8 | Refresh rotation: refresh → new pair, the old refresh token now `invalid_grant`; presenting the old one again also kills the new pair (401 on `/mcp` with the new access token); an access token expired by `now` → 401 | pytest |
| 9 | `/revoke` of a refresh token → its family's access token gets 401 | pytest |
| 10 | `LA_CARTE_SIGNUP=allowlist`: a non-listed email ends at `redirect_uri?error=access_denied&error_description=not_allowed`, and `user`, `identity`, `apitoken`, `authcode` gain no row; the owner email is accepted without being listed; with an empty list only the owner gets in. `LA_CARTE_SIGNUP` unset or `open`: any verified email creates an account, whatever `LA_CARTE_ALLOWED_EMAILS` holds. `LA_CARTE_SIGNUP=closed` → refuses to start. No response body or page contains "invite" | pytest |
| 11 | Owner claim: with a migrated owner row (030a), the first sign-in with the verified owner email attaches `(provider, sub)` and the tokens read the migrated deck; a later sign-in with the same email but another `sub` → `email_in_use`, no row; a later sign-in by `sub` with a changed email updates `user.email` | pytest |
| 12 | Unverified email (fake `unverified…` / Google `email_verified: false`) → `access_denied`/`unverified_email`, no row | pytest |
| 13 | `GoogleProvider` (injected transport returning a canned token response): sends `scope=openid email`, PKCE, `prompt=select_account`; rejects wrong `iss`, wrong `aud`, expired `exp`, wrong `nonce`; keeps nothing but `sub` + email (no Google token in any table); revokes the Google access token (030e AC 12) | pytest |
| 14 | Unknown or expired `state` on the callback → 400 HTML page, no redirect; an agent client's callback without the `lc_auth` cookie, or with another one → the same 400; an iOS callback with a stale `lc_auth` from another request succeeds | pytest |
| 15 | `POST /me/tokens` with an `la-carte-ios` access token → 201 with `token` once (`lc_pat_…`), `expires_at` = now + N days when given; the PAT works on REST and `/mcp` (`deck`) or only `/stats` (`stats`); with a PAT or an agent client's access token → 403; with a refresh token → 401 | pytest |
| 16 | `FakeProvider` with `LA_CARTE_PUBLIC_URL=https://example.com` → refuses to start; Google without client secret → refuses to start; no provider → `/authorize` ends in `temporarily_unavailable` while PATs keep working | pytest |
| 17 | (moved to 030h) | — |
| 18 | `scripts/e2e.sh` (qa-validator) runs its APIs with `LA_CARTE_IDENTITY_PROVIDER=fake`, signs in as `la-carte-ios` over HTTP (curl, PKCE), mints a PAT with `POST /me/tokens`, seeds with it, and the live UI tests pass | UI (live) |
| 19 | On the deployed server: `claude mcp add --transport http la-carte <PUBLIC>/mcp` then `/mcp` → Google → `deck_stats` works; claude.ai custom connector with the same URL works; if the allowlist is set, an unlisted Google account is refused (manager with the user) | manual |

## API / MCP changes
As above. MCP tools: none new. The SDK's routes plus ours; `POST /me/tokens`. New tables `oauthclient`,
`authrequest`, `authcode` (`create_all`, no migration). `apitoken` from 030a gains `access` / `refresh` rows.

## Accessibility identifiers
None (server HTML only; the consent button has `id="continue"` for pytest).

## Out of scope
- CIMD (backlog: SDK lacks it; Claude and ChatGPT fall back to DCR). Sign in with Apple (030e app, 030g web).
  Remembered consent. Linking a second provider. Cleanup of stale DCR clients. Rate limiting of `/register` and
  `/authorize` (backlog before the App Store).
