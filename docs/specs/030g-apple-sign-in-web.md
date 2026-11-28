# 030g — Sign in with Apple for agents (web consent page)

Status: ready (not an App Store blocker: do it after 030e/030f)
Owners: api-engineer → code-reviewer → qa-validator (pytest; manual claude.ai connector check with the user)
Depends on: 030b (consent page, callback, `authrequest`), 030e (`AppleProvider`, Apple config, account resolution).
Overview: [030](030-accounts-google-login.md).
Design reference: none for the app. Server HTML as in 030b decision 4; Apple's button per the HIG "Sign in with
Apple" (black/white, "Continue with Apple").

## Goal
A user whose account signs in with Apple can connect an agent (Claude, ChatGPT, Cursor) over OAuth too: the consent
page offers "Continue with Apple" next to "Continue with Google". Without this part, Apple users connect agents with
a PAT from the app (030d), which works but is second best.

## User stories
- As an Apple-account user, I add la-carte as a claude.ai connector, choose "Continue with Apple", sign in with my
  Apple ID in the browser, and Claude reads my deck.

## Decisions
1. **Consent page** (030b decision 4) shows two buttons when Apple is configured (030e decision 6 plus
   `LA_CARTE_APPLE_SERVICES_ID`): "Continue with Apple" (`id="continue-apple"`) above "Continue with Google"
   (`id="continue"`), same size. Each is its own form (`POST /oauth/consent`, fields `request` and
   `provider=apple|google`). Without Apple config, the page is unchanged. `authrequest.provider` records the choice.
2. **`AppleProvider` web methods** (implements 030b's `IdentityProvider`):
   - `authorization_url`: `https://appleid.apple.com/auth/authorize` with `client_id` = `LA_CARTE_APPLE_SERVICES_ID`,
     `redirect_uri=<PUBLIC>/oauth/callback`, `response_type=code`, `response_mode=form_post` (Apple requires it when
     a scope is requested), `scope=email`, `state`, `nonce`. Apple doesn't use our PKCE challenge: the
     `client_secret` JWT authenticates the exchange.
   - `verify(code, nonce)`: exchange at `https://appleid.apple.com/auth/token` with `client_id` = the Services ID
     and its `client_secret` (030e decision 2); read the `id_token` from that TLS response (as Google: no JWKS
     needed there); check `iss`, `aud` = Services ID, `exp`, `nonce`, `email_verified`; keep the `refresh_token` on
     the identity with `provider_client_id` = the Services ID (030e decision 3).
   - The Services ID must be grouped with the app's primary App ID so web and app sign-ins give the **same `sub`**
     (user action in 030); a test can't prove it, the manual check does (AC 6).
3. **Callback**: `/oauth/callback` also accepts `POST` (form `code`, `state`, optional `user`, `error`). Apple's
   cross-site POST carries no `SameSite=Lax` cookie, so `lc_auth` is absent: 030b already tolerates an absent cookie
   (only a present, different one is refused); `state` stays single-use and 256-bit. Apple's `user` form field (name
   JSON on first sign-in) is ignored and never stored. `error=user_cancelled_authorize` → `access_denied`/
   `cancelled`.
4. Account resolution, sign-up mode, email collision (`use_google`) and token minting: unchanged (030b/030e).
5. Config: `LA_CARTE_APPLE_SERVICES_ID` (optional; web Apple is on only with it and the 030e variables).

## Acceptance criteria
All with the injected `httpx` transport and test keys: no test calls Apple.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | With Apple configured, the consent page has `continue-apple` and `continue`; without `LA_CARTE_APPLE_SERVICES_ID` only `continue` | pytest |
| 2 | `POST /oauth/consent` with `provider=apple` → 303 to `appleid.apple.com/auth/authorize` carrying the Services ID, `response_mode=form_post`, `scope=email`, our `state` and `nonce`, `redirect_uri=<PUBLIC>/oauth/callback` | pytest |
| 3 | Full agent flow: `POST /oauth/callback` (form, no cookie) with a code the stub exchanges for a valid `id_token` → 302 to the client's redirect URI with `code`, `state`, `iss` → `/token` → the access token reads that Apple user's deck; the identity stores the refresh token with the Services ID | pytest |
| 4 | Wrong `aud` (the bundle id instead of the Services ID), wrong nonce, expired → `access_denied`/`sign_in_failed`, no row; `error=user_cancelled_authorize` → `access_denied`/`cancelled`; the `user` form field is not stored anywhere | pytest |
| 5 | An existing Apple account (created in the app, 030e) signing in on the web with the same `sub` reaches the same deck | pytest |
| 6 | On the deployed server: claude.ai custom connector → "Continue with Apple" → the same deck as the iPhone's Apple account (manager with the user) | manual |

## API / MCP changes
`POST /oauth/callback` (form) in addition to `GET`. Consent form field `provider`. No MCP tool change.

## Accessibility identifiers
None (server HTML; `id="continue-apple"` for pytest).

## Out of scope
- Apple in the iOS app's browser flow (the app uses the native sheet, 030f). Linking providers.
