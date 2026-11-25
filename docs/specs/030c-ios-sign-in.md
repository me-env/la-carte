# 030c — Sign in with Google (iOS)

Status: ready
Owners: design-lead (button + screen note, first) → ios-engineer → code-reviewer → qa-validator; release-engineer for
the default-URL build setting
Depends on: the contract in [030](030-accounts-google-login.md) / [030b](030b-oauth-google.md); builds and tests on
mock now, ships after 030b is deployed. Touches `APIClient/**`, `SettingsFeature/**`, `AppFeature/**`, a small
`StudyFeature` / `DeckFeature` delegate: schedule after in-flight Study/Deck work, one Study touch only.
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg (one centered message + one action,
like 008's "Connect your deck"), 05-theme-forest.jpg; Google's "Sign in with Google" branding guidelines
(developers.google.com/identity/branding-guidelines) for the button.

## Goal
A new user opens the app, taps "Continue with Google", picks their account in a system browser sheet, and lands on
their deck. They stay signed in (silent token refresh), can sign out, and can delete their account from Settings.
No Google SDK, no password, no token to type.

## User stories
- As a friend, I install the app, tap "Continue with Google", and see my (empty) deck.
- As someone not invited yet, I'm told "This deck is invite-only for now." and nothing else happens.
- As the user, I'm never asked to sign in again unless I sign out, delete my account, or my session is revoked.
- As the user, I delete my account in Settings, confirm once, and I'm back on the sign-in screen with nothing left.
- As the user, my widget keeps showing my stats while I'm signed in.

## Decisions
1. **`ASWebAuthenticationSession`, no Google SDK.** The app is OAuth client `la-carte-ios` of *our* server (030b),
   not of Google; Google sees only our server's Web client. `callbackURLScheme: "lacarte"`, callback
   `lacarte://oauth` (no Info.plist URL type needed), PKCE S256 (`code_verifier` 43–128 chars from
   `SecRandomCopyBytes`), random `state`, `scope=deck`, `resource=<base>/mcp`.
   `prefersEphemeralWebBrowserSession = true`: no shared Safari cookies (privacy; one sign-in per install is
   fine), and the system "wants to use … to sign in" alert is not shown, which also keeps UI tests free of a
   springboard alert (QA confirms on iOS 26/27; if the alert still shows, the UI test taps it).
2. **Callback checks**: `state` must equal ours; `iss` must equal the base URL's origin; `error=access_denied` maps
   `error_description` `not_invited` → `.notInvited`, `unverified_email` → `.unverifiedEmail`, `cancelled` /
   user-cancelled session (`ASWebAuthenticationSessionError.canceledLogin`) → `.cancelled`; anything else →
   `.failed`. Then `POST /token` (form-encoded).
3. **Session storage**: Keychain generic password, service `la-carte`, account `session`, value JSON
   `{baseURL, accessToken, refreshToken, expiresAt}`, `kSecAttrAccessibleAfterFirstUnlock`, **no** access group
   (the app only; the widget never sees it). A session is valid only for its `baseURL`.
4. **Refresh** (`SessionStore`, an actor in `APIClient`): before a request, an access token expiring within 60 s is
   refreshed; a 401 on a request sent with a session token → one refresh, one retry. Concurrent requests share one
   in-flight refresh. `invalid_grant` → session deleted → the request fails `.unauthorized`. Network failure during
   refresh → the session is kept, the request fails as offline (the existing "Can't reach your deck").
5. **Credential order** (per request, as today): launch env `LA_CARTE_API_TOKEN` > session > legacy Keychain
   `api-token` (the owner's old token, now a PAT: the user's phone keeps working until they sign in). Signing in or
   out deletes `api-token`. **Server URL**: launch env `LA_CARTE_API_URL` > stored `apiURL` > Info.plist
   `LaCarteDefaultAPIURL` (from build setting `LA_CARTE_DEFAULT_API_URL`, empty in the repo, set by CI from a
   repository variable). `isConfigured` = a URL and a credential.
6. **Widget**: after sign-in the app calls `POST /me/tokens {name: "Widget", scope: "stats"}` and stores the token
   in the App Group Keychain group, account `widget-token`. The widget resolves env > `widget-token` > `api-token`
   and never refreshes. Sign-out and delete remove it (`DELETE /me/tokens/{id}` best effort, then the Keychain
   item) and reload widget timelines. If minting fails, sign-in still succeeds; the next launch retries.
7. **Signed out** = no credential. Study's existing `.notSetUp` check and every `.unauthorized` (after refresh)
   in Study and Deck send `delegate(.signInRequired)`; `AppFeature` presents `SignInFeature` full screen
   (`.fullScreenCover`, not dismissible). Settings' URL + token entry (spec 008) is replaced: the token field goes
   away (PATs are for scripts, 030d), the server URL is edited on the sign-in screen only.
8. **Sign-in screen** (design-lead finalises): centered `LaCarteLogo`, "la-carte", "Sign in to get your deck.",
   one button "Continue with Google" with Google's "G" mark per their branding guidelines (glass/prominent per
   design-system, design-lead decides), a `ProgressView` in the button while signing in, one caption line for the
   error, and a footer: "Server: <host>" + "Change" (reveals a URL field) and "Privacy" (opens `<base>/privacy` in
   Safari). Messages: not invited "This deck is invite-only for now."; unverified "Use a Google account with a
   verified email."; failed "Couldn't sign in. Try again."; arriving after an expired session "You were signed out.
   Sign in again."; no URL resolvable: the button is disabled and the URL field is shown.
9. **Settings → Account section** (first section): the email from `GET /me` (or "Signed in" while loading /
   offline), "Sign out" (no confirmation; revokes the refresh token via `POST /revoke` best effort, deletes the
   session, widget token and `api-token`), "Delete account" (destructive) → alert "Delete your account? Your deck,
   reviews and settings are deleted from the server. This can't be undone." with "Delete Account" (destructive) and
   "Cancel" → `DELETE /me` → on 204 same local cleanup as sign out → sign-in screen; on failure alert "Couldn't
   delete your account. Try again." and nothing changes. A "Privacy policy" link. Server section: the URL as
   read-only text + the existing Test button.
10. **Mock modes**: `LA_CARTE_API=mock*` starts signed in as `you@example.com` (unchanged screens for existing UI
    tests). `LA_CARTE_AUTH=signed-out` starts signed out with a mock `AuthClient` whose sign-in succeeds after
    0.3 s; `LA_CARTE_AUTH=not-invited` fails with `.notInvited`. No browser in mock modes.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Signed out (mock `LA_CARTE_AUTH=signed-out`), launch shows the sign-in screen: `signIn.google`, `signIn.server` showing the host, `signIn.privacy`; Study is not reachable | UI |
| 2 | Tapping `signIn.google` shows progress in the button, then the sign-in screen goes away and Study shows the mock deck | both |
| 3 | `LA_CARTE_AUTH=not-invited`: tapping `signIn.google` shows `signIn.error` "This deck is invite-only for now." and stays on the screen | both |
| 4 | A cancelled browser sheet returns to the idle screen with no error | unit |
| 5 | `SignInFeature`: `.failed` → "Couldn't sign in. Try again."; `.unverifiedEmail` → its message; a second tap while signing in does nothing | unit |
| 6 | No resolvable server URL: `signIn.google` is disabled and `signIn.serverURL` is shown; typing a valid https URL enables it and stores `apiURL` | both |
| 7 | Live `AuthClient` (URLProtocol stub + injected web session): builds `/authorize` with `client_id=la-carte-ios`, `redirect_uri=lacarte://oauth`, S256 challenge of the verifier it later sends, `state`, `scope=deck`, `resource=<base>/mcp`; rejects a callback with another `state` or `iss` (`.failed`); exchanges the code at `/token` and stores the session in the Keychain item of decision 3 | unit |
| 8 | Refresh: an access token expiring in 30 s is refreshed before the request; a 401 triggers exactly one refresh + one retry; two concurrent requests cause one refresh; `invalid_grant` deletes the session and the request fails `.unauthorized`; a network error keeps the session | unit |
| 9 | Study `.unauthorized` (after refresh) or no credential → `delegate(.signInRequired)` → `AppFeature` presents `.signIn`; `signIn(.delegate(.signedIn))` dismisses it and sends `study(.deckChanged)` | unit |
| 10 | Settings shows `settings.account.email` = the mock email; no `settings.token` field exists | UI |
| 11 | Tapping `settings.signOut` calls `authClient.signOut` and shows the sign-in screen | both |
| 12 | Tapping `settings.deleteAccount` shows the confirmation alert; Cancel changes nothing; "Delete Account" calls `authClient.deleteAccount` and shows the sign-in screen; a failing delete shows "Couldn't delete your account. Try again." and stays signed in | both |
| 13 | After sign-in the live client mints a `stats` token and stores it under `widget-token`; sign-out removes it; the widget's token resolution prefers it over `api-token` | unit |
| 14 | A legacy `api-token` in the Keychain keeps the app signed in (no sign-in screen); signing in deletes it | unit |
| 15 | `DecodingTests`: `TokenResponse` (`access_token`, `token_type`, `expires_in`, `refresh_token`, `scope`), OAuth error `{error, error_description}`, `Me`, `PersonalToken` from the server's JSON | unit |
| 16 | Live e2e against `scripts/e2e.sh` (fake provider, `LA_CARTE_FAKE_EMAIL` allowlisted, no launch token): tapping `signIn.google` opens and closes the auth sheet by itself and Study shows the seeded cards | UI (live) |
| 17 | Screenshots, light + dark: `signin-idle`, `signin-not-invited`, `signin-server`, `settings-account`, `settings-delete-confirm` | UI |
| 18 | The user signs in with Google on the iPhone against the deployed server and sees their existing deck; the widget still shows stats (manager with the user) | manual |

## Screens & states
- **Sign in**: idle; signing in (progress in the button); error line (not invited / unverified / failed / signed
  out); server field shown (no URL, or "Change" tapped). Screenshots in AC 17.
- **Settings**: Account section on top (email, Sign out, Delete account, Privacy policy); delete confirmation
  alert; delete error alert.

## TCA shape (iOS)
- New module **`SignInFeature`** (child of `AppFeature`; deps `APIClient`, `DesignSystem`):
  - State: `@Shared(.appStorage("apiURL")) apiURL`, `serverURLText: String`, `isEditingServer: Bool`,
    `status: Status` (`idle`, `signingIn`, `failed(Message)`), `Message` = `notInvited | unverifiedEmail | failed |
    sessionExpired`.
  - Actions: `signInButtonTapped`, `signInResponse(Result<Void, SignInError>)`, `changeServerButtonTapped`,
    `serverURLChanged(String)`, `delegate(.signedIn)`.
  - Dependencies: `authClient`, `apiClient` (`baseURL`).
- **`AuthClient`** (`@DependencyClient`, in `APIClient`, no TCA import): `signIn(URL) async throws(SignInError)`,
  `signOut() async`, `deleteAccount() async throws`, `me() async throws -> Me`. Live = PKCE +
  `ASWebAuthenticationSession` (behind a small `WebAuthSession` closure so tests inject the callback URL) +
  `SessionStore` + `TokenStore` items `session`, `widget-token`. In-memory value per decision 10.
- **`AppFeature`**: `Destination` gains `case signIn(SignInFeature)` (full-screen cover). Handles
  `study(.delegate(.signInRequired))`, `deck(.delegate(.signInRequired))`, `settings(.delegate(.signedOut))` →
  `.signIn(SignInFeature.State(message: …))`; `signIn(.delegate(.signedIn))` → `destination = nil` +
  `study(.deckChanged)`.
- **`StudyFeature` / `DeckFeature`**: add `delegate(.signInRequired)`, sent where they set `.notSetUp` /
  `.unauthorized` today. No other change.
- **`SettingsFeature`**: State drops `token`; adds `email: String?`, `@Presents alert`. Actions add
  `signOutButtonTapped`, `deleteAccountButtonTapped`, `alert(.presented(.confirmDelete))`, `meResponse`,
  `deleteResponse`, `delegate(.signedOut)`.
- `docs/architecture.md` (architect, done with this spec): module list, runtime configuration, Keychain items.

## API / MCP changes
None beyond 030a/030b. `APIClient` adds `Me`, `TokenResponse`, `PersonalToken` models + `DecodingTests`.

## Accessibility identifiers
- `signIn.google`: Continue with Google
- `signIn.error`: the error line
- `signIn.server`: "Server: <host>" caption + Change button
- `signIn.serverURL`: the server URL field
- `signIn.privacy`: privacy link
- `settings.account.email`: the signed-in email
- `settings.signOut`, `settings.deleteAccount`: buttons
- `settings.deleteAccount.confirm`: the alert's destructive button
- `settings.privacy`: privacy policy link
- Removed: `settings.token`, `settings.token.reveal`; `settings.url` becomes read-only text (same id)

## Out of scope
- Sign in with Apple (030 App Store note). PAT management UI (030d). Universal-link callback / associated domains.
  Signing in to two servers at once. Account switching. VoiceOver, Dynamic Type, localisation (per the user).
