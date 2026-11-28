# 030e — Sign in with Apple (API): native token exchange, revocation on deletion

Status: ready
Owners: api-engineer → code-reviewer → qa-validator (pytest; manual check on the iPhone with the user)
Depends on: 030a (tables, `DELETE /me`) and 030b (token minting, refresh families, sign-up mode, email-collision rule)
merged on the accounts branch. Overview, principles and env: [030](030-accounts-google-login.md). The app side is
[030f](030f-apple-sign-in-ios.md); agents signing in with Apple on the web is [030g](030g-apple-sign-in-web.md).
Design reference: none (no screen).


> **Amended by [032](032-encryption.md):** `POST /oauth/apple` returns *locked* tokens like the iOS code flow; the app
> then calls `POST /me/key` or `POST /me/unlock` (032b decisions 5–7).
## Goal
The iOS app signs a user in with Apple (guideline 4.8) and gets la-carte tokens, exactly like the Google path ends.
When an account with an Apple identity is deleted, the server revokes the user's Sign in with Apple authorization
(5.1.1(v)). Google sign-in no longer leaves a grant behind.

## User stories
- As an iPhone user, I tap "Continue with Apple", confirm with Face ID, and land on my deck.
- As an App Store reviewer, I use my own Apple ID and get an empty deck, with no invite and no demo account.
- As a user who deletes their account, la-carte disappears from "Apps Using Apple ID" in my Apple account settings.

## Ground (from Apple's and Google's docs; api-engineer re-checks each item against the docs while implementing
and notes any difference in the PR, since the Apple pages could not be fetched automatically on 2026-11-28)
- Native flow: the app gets an **identity token** (JWT, RS256, keys at `https://appleid.apple.com/auth/keys`, `iss`
  `https://appleid.apple.com`, `aud` = the bundle id, `exp`, `sub`, `nonce` = what the app put in the request,
  `email`, `email_verified`, `is_private_email`; the two booleans may arrive as strings `"true"`/`"false"`) and an
  **authorization code** (single use, valid 5 minutes).
- `POST https://appleid.apple.com/auth/token` (form: `client_id`, `client_secret`, `code`,
  `grant_type=authorization_code`) → `{access_token, refresh_token, id_token, …}`. `client_id` for a native code is
  the bundle id.
- `client_secret` is a JWT we sign: header `alg: ES256`, `kid` = the Sign in with Apple key id; claims `iss` = team
  id, `iat`, `exp` (at most 6 months later), `aud` = `https://appleid.apple.com`, `sub` = the `client_id`.
- `POST https://appleid.apple.com/auth/revoke` (form: `client_id`, `client_secret`, `token`,
  `token_type_hint=refresh_token`) → 200; it ends the user's authorization for the app.
- Apple's account deletion page: "Apps that support Sign in with Apple should use the Sign in with Apple REST API to
  revoke user tokens" (developer.apple.com/support/offering-account-deletion-in-your-app, read 2026-11-28).
- Google: `POST https://oauth2.googleapis.com/revoke` (form `token`) revokes the token and the user's grant to our
  Google project.

## Decisions
1. **Endpoint** `POST /oauth/apple` (public path, form-encoded like `/token`): `client_id` (must be `la-carte-ios`,
   else 400 `invalid_client`), `identity_token`, `authorization_code`, `nonce` (the raw nonce; the app sent its
   SHA-256 hex to Apple). Success → 200 with the **same body as `/token`**: `{access_token, token_type: "Bearer",
   expires_in: 3600, refresh_token, scope: "deck"}`, a new refresh family, `client_id = la-carte-ios`,
   `resource = <PUBLIC>/mcp`. Errors → 400 `{error, error_description}`:
   - `invalid_grant` / `sign_in_failed`: bad signature, unknown `kid` (after one JWKS refetch), wrong `iss`, `aud`
     ≠ `LA_CARTE_APPLE_BUNDLE_ID`, expired, `nonce` ≠ SHA-256 hex of the raw nonce, missing `sub`, email not
     verified, the code exchange failing, or the exchanged `id_token`'s `sub` differing from the identity token's.
   - `access_denied` / `not_allowed`: sign-up mode refuses a new account (030 "Sign-up mode").
   - `access_denied` / `use_google`: the email belongs to an account that signs in with Google (030 principle 4).
   - `temporarily_unavailable`: Apple not configured (decision 6).
2. **`AppleProvider`** (`identity.py`, next to `GoogleProvider`): `verify_native(identity_token, code, raw_nonce)
   -> VerifiedIdentity` and `revoke(refresh_token, client_id)`. JWT work uses **PyJWT with `cryptography`** (new
   runtime dependency `pyjwt[crypto]`; `cryptography` is already installed through `mcp`): `PyJWKClient`-style key
   lookup with the JWKS cached in memory for 24 h and refetched once on an unknown `kid`; the `client_secret` is
   minted per call (cheap, nothing to cache or rotate). HTTP goes through the injectable `httpx` transport of 030b.
   Every Apple failure raises `IdentityError(reason)`; logs never contain a token, a code, a nonce or an email.
3. **Code exchange is required.** After the identity token checks, the server exchanges `authorization_code` and
   keeps Apple's `refresh_token` on the identity (`identity.provider_token`, `identity.provider_client_id` = the
   `client_id` used, both from 030a). Without it the account could not be revoked later, so a failed exchange fails
   the sign-in and writes nothing. Each sign-in replaces the stored token with the new one. Why storing it is fine:
   it can only be used together with our private key (it reads no user data; we use it only to revoke), it is
   deleted with the account, and Apple documents this exact use.
4. **Account resolution**: the same function as 030b's callback (one code path for every provider): `(apple, sub)`
   → its user (email updated when Apple sends one and it doesn't collide); else owner claim (exact
   `LA_CARTE_OWNER_EMAIL`, unclaimed owner row); else the email-collision rule; else sign-up mode; else create user
   + identity. Apple's private relay emails (`…@privaterelay.appleid.com`) are stored as the email like any other;
   we never send email, so no relay registration is needed. Apple sends no name and we request none.
5. **Revocation on deletion** (`DELETE /me`, extends 030a decision 7): before the delete transaction, for each of the
   user's identities whose provider has `revoke` and whose `provider_token` is set, call it (timeout 5 s each).
   A failed revoke is logged (`"apple revoke failed: <status>"`, nothing personal) and **does not stop the
   deletion**: the user's data must go even if Apple is down. Then 030a's deletion runs unchanged.
6. **Config** (all optional; Apple is on only when the first four are set): `LA_CARTE_APPLE_TEAM_ID`,
   `LA_CARTE_APPLE_KEY_ID`, `LA_CARTE_APPLE_PRIVATE_KEY_B64` (the `.p8` file, base64 on one line: secret),
   `LA_CARTE_APPLE_BUNDLE_ID` (the app's bundle id; the `aud` of native tokens). Some but not all of the four set,
   or a key that doesn't parse as an EC P-256 private key → refuse to start with a message naming the variable
   (never its value). None set → `/oauth/apple` answers `temporarily_unavailable` and everything else works.
7. **Google grant (amends 030b decision 5)**: right after `GoogleProvider.verify` reads the ID token, it posts
   Google's access token to `https://oauth2.googleapis.com/revoke` (best effort, 5 s, failure logged without the
   token) and drops it. So no Google grant outlives a sign-in, and `DELETE /me` has nothing to revoke at Google.
   Cost: Google shows its consent screen at every sign-in (once per app install, once per agent connection), which
   is acceptable. The manual check (AC 12) confirms la-carte is gone from the Google account's third-party
   connections after a sign-in.
8. `docker-compose.yml` passes the four Apple variables through (empty defaults). `docs/deploy.md`: the variables
   and how to make the base64 (`base64 -i AuthKey_<KEYID>.p8 | tr -d '\n'`).

## Acceptance criteria
All with a test RSA key served as the JWKS and a test EC key as our Apple key, through an injected `httpx`
transport: no test calls Apple or Google.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | A valid identity token + code + raw nonce for a new `sub` → 200 with the `/token` body; the access token lists tools on `/mcp` and `GET /me` returns `{…, email, provider: "apple"}`; `identity` holds `("apple", sub)` with the exchanged refresh token and `provider_client_id` = the bundle id | pytest |
| 2 | The same `sub` signing in again → the same user; the stored Apple token is replaced; a changed email in the token updates `user.email` | pytest |
| 3 | Each of: bad signature, unknown `kid` still unknown after one refetch, wrong `iss`, wrong `aud`, expired `exp`, wrong nonce, `email_verified` false (bool or `"false"`), code exchange 400, exchanged `sub` ≠ identity `sub` → 400 `invalid_grant`/`sign_in_failed`, and no `user`, `identity` or `apitoken` row is written | pytest |
| 4 | `email_verified: "true"` (string) and `true` (bool) are both accepted; a private relay email is stored as is | pytest |
| 5 | The JWKS is fetched once for several sign-ins; a token with a new `kid` triggers exactly one refetch | pytest |
| 6 | The `client_secret` sent to Apple is an ES256 JWT with `kid` = key id, `iss` = team id, `sub` = bundle id, `aud` = `https://appleid.apple.com`, `exp` > `iat` and ≤ `iat` + 180 days, verifiable with the test public key | pytest |
| 7 | Email collision: an Apple sign-in whose email equals a Google-backed account's email → 400 `access_denied`/`use_google`, no row written, the Google account untouched; the reverse (a Google sign-in on an Apple-backed email) ends at `redirect_uri?error=access_denied&error_description=use_apple` | pytest |
| 8 | Owner claim: an unclaimed owner row and an Apple sign-in with exactly `LA_CARTE_OWNER_EMAIL` → the identity attaches and the tokens read the migrated deck | pytest |
| 9 | Sign-up mode `allowlist` refuses an unlisted Apple email (`not_allowed`, no row); mode `open` (default) creates the account | pytest |
| 10 | `DELETE /me` for an Apple user posts to Apple's revoke endpoint with the stored refresh token, `token_type_hint=refresh_token`, `client_id` = the stored one and a valid `client_secret`, then deletes everything (030a AC 10); with the revoke answering 500 or timing out, the account and its data are still deleted and the call still returns 204 | pytest |
| 11 | `client_id` other than `la-carte-ios` → 400 `invalid_client`; Apple not configured → `temporarily_unavailable`; three of the four Apple variables set → refuses to start naming the missing one; a key that isn't EC P-256 → refuses to start; no log line of a full test run contains a token, a code, a nonce, the key or an email (caplog) | pytest |
| 12 | A Google sign-in posts the Google access token to the revoke endpoint once; a failing revoke doesn't fail the sign-in; no Google token is stored | pytest |
| 13 | On the deployed server with the user: sign in with Apple on the iPhone (030f build), then Settings → Delete Account; la-carte is gone from the Apple ID's "Sign in with Apple" apps; after a Google sign-in, la-carte is not listed in the Google account's third-party connections (manager with the user) | manual |

## API / MCP changes
- New: `POST /oauth/apple` (above). `GET /me` gains `provider: "google" | "apple" | null` (030a).
- MCP: none. Tables: none new (030a's `identity` carries `provider_token`, `provider_client_id`).
- iOS: `AuthClient.signInWithApple` calls it (030f); `TokenResponse` and the OAuth error shape are already decoded
  (030c).

## Accessibility identifiers
None.

## Out of scope
- Apple's server-to-server notifications (`consent-revoked`, `account-delete`, email changes) and checking the
  credential state at launch: backlog. Linking Apple and Google on one account: backlog. Requesting the user's name.
  Agents signing in with Apple on the web (030g).
