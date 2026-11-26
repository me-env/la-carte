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
- As someone whose account the server refuses, I'm told "This account can't be used yet." and nothing else happens.
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
   `error_description` `not_allowed` → `.notAllowed`, `unverified_email` → `.unverifiedEmail`, `cancelled` /
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
   out deletes `api-token`. **Server URL is fixed at build time** (user decision 2026-11-26: the app offers no way
   to connect another server): launch env `LA_CARTE_API_URL` (UI tests, development) > Info.plist
   `LaCarteDefaultAPIURL` (from build setting `LA_CARTE_DEFAULT_API_URL`, empty in the repo, set by CI from a
   repository variable; the app's and the widget's Info.plist both carry it). The stored `apiURL` (spec 008) is no
   longer read or written. `isConfigured` = a URL and a credential. Self-hosters build from source with their own
   URL (030 "Self-hosting"): ios-engineer adds a commented `LA_CARTE_DEFAULT_API_URL` line to
   `ios/Config/Signing.local.xcconfig.example`.
6. **Widget**: after sign-in the app calls `POST /me/tokens {name: "Widget", scope: "stats"}` and stores the token
   in the App Group Keychain group, account `widget-token`. The widget resolves env > `widget-token` > `api-token`
   and never refreshes. Sign-out and delete remove it (`DELETE /me/tokens/{id}` best effort, then the Keychain
   item) and reload widget timelines. If minting fails, sign-in still succeeds; the next launch retries.
7. **Signed out** = no credential. Study's existing `.notSetUp` check and every `.unauthorized` (after refresh)
   in Study and Deck send `delegate(.signInRequired)`; `AppFeature` presents `SignInFeature` full screen
   (`.fullScreenCover`, not dismissible). Settings' URL + token entry (spec 008) is removed: the token field goes
   away (PATs are for scripts, 030d) and there is no server URL anywhere in the app.
8. **Sign-in screen** (design-lead finalises): centered `LaCarteLogo`, "la-carte", "Sign in to get your deck.",
   one button "Continue with Google" with Google's "G" mark per their branding guidelines (glass/prominent per
   design-system, design-lead decides), a `ProgressView` in the button while signing in, one caption line for the
   error, and a footer link "Privacy" (opens `<base>/privacy` in Safari). Messages: refused by the server "This
   account can't be used yet."; unverified "Use a Google account with a verified email."; failed "Couldn't sign
   in. Try again."; arriving after an expired session "You were signed out. Sign in again."; no URL in the build
   (a from-source build without `LA_CARTE_DEFAULT_API_URL`): the button is disabled and the error line reads "This
   build has no server set." (developer-only state; "Privacy" is hidden since there is no base URL).
9. **Settings → Account section** (first section): the email from `GET /me` (or "Signed in" while loading /
   offline), "Sign out" (no confirmation; revokes the refresh token via `POST /revoke` best effort, deletes the
   session, widget token and `api-token`), "Delete account" (destructive) → alert "Delete your account? Your deck,
   reviews and settings are deleted from the server. This can't be undone." with "Delete Account" (destructive) and
   "Cancel" → `DELETE /me` → on 204 same local cleanup as sign out → sign-in screen; on failure alert "Couldn't
   delete your account. Try again." and nothing changes. A "Privacy policy" link. The Server section (URL, Test
   connection, status) is removed: the email row already shows the app reaches its server.
10. **Mock modes**: `LA_CARTE_API=mock*` starts signed in as `you@example.com` (unchanged screens for existing UI
    tests). `LA_CARTE_AUTH=signed-out` starts signed out with a mock `AuthClient` whose sign-in succeeds after
    0.3 s; `LA_CARTE_AUTH=not-allowed` fails with `.notAllowed`. No browser in mock modes.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Signed out (mock `LA_CARTE_AUTH=signed-out`), launch shows the sign-in screen: `signIn.google`, `signIn.privacy`; no server URL, host or "Change" control exists; Study is not reachable | UI |
| 2 | Tapping `signIn.google` shows progress in the button, then the sign-in screen goes away and Study shows the mock deck | both |
| 3 | `LA_CARTE_AUTH=not-allowed`: tapping `signIn.google` shows `signIn.error` "This account can't be used yet." and stays on the screen; no text on the screen mentions invites | both |
| 4 | A cancelled browser sheet returns to the idle screen with no error | unit |
| 5 | `SignInFeature`: `.failed` → "Couldn't sign in. Try again."; `.unverifiedEmail` → its message; a second tap while signing in does nothing | unit |
| 6 | URL resolution: launch env `LA_CARTE_API_URL` wins over Info.plist `LaCarteDefaultAPIURL`; a stored `apiURL` default is ignored; with neither, `SignInFeature` disables sign-in and shows "This build has no server set." | unit |
| 7 | Live `AuthClient` (URLProtocol stub + injected web session): builds `/authorize` with `client_id=la-carte-ios`, `redirect_uri=lacarte://oauth`, S256 challenge of the verifier it later sends, `state`, `scope=deck`, `resource=<base>/mcp`; rejects a callback with another `state` or `iss` (`.failed`); exchanges the code at `/token` and stores the session in the Keychain item of decision 3 | unit |
| 8 | Refresh: an access token expiring in 30 s is refreshed before the request; a 401 triggers exactly one refresh + one retry; two concurrent requests cause one refresh; `invalid_grant` deletes the session and the request fails `.unauthorized`; a network error keeps the session | unit |
| 9 | Study `.unauthorized` (after refresh) or no credential → `delegate(.signInRequired)` → `AppFeature` presents `.signIn`; `signIn(.delegate(.signedIn))` dismisses it and sends `study(.deckChanged)` | unit |
| 10 | Settings shows `settings.account.email` = the mock email; no `settings.token`, `settings.url` or `settings.test` element exists | UI |
| 11 | Tapping `settings.signOut` calls `authClient.signOut` and shows the sign-in screen | both |
| 12 | Tapping `settings.deleteAccount` shows the confirmation alert; Cancel changes nothing; "Delete Account" calls `authClient.deleteAccount` and shows the sign-in screen; a failing delete shows "Couldn't delete your account. Try again." and stays signed in | both |
| 13 | After sign-in the live client mints a `stats` token and stores it under `widget-token`; sign-out removes it; the widget's token resolution prefers it over `api-token` | unit |
| 14 | A legacy `api-token` in the Keychain keeps the app signed in (no sign-in screen); signing in deletes it | unit |
| 15 | `DecodingTests`: `TokenResponse` (`access_token`, `token_type`, `expires_in`, `refresh_token`, `scope`), OAuth error `{error, error_description}`, `Me`, `PersonalToken` from the server's JSON | unit |
| 16 | Live e2e against `scripts/e2e.sh` (fake provider, no `LA_CARTE_ALLOWED_EMAILS`, no launch token): tapping `signIn.google` opens and closes the auth sheet by itself and Study shows the seeded cards | UI (live) |
| 17 | Screenshots, light + dark: `signin-idle`, `signin-not-allowed`, `settings-account`, `settings-delete-confirm` | UI |
| 18 | The user signs in with Google on the iPhone against the deployed server and sees their existing deck; the widget still shows stats (manager with the user) | manual |

## Screens & states
- **Sign in**: idle; signing in (progress in the button); error line (not allowed / unverified / failed / signed
  out / no server in the build). Screenshots in AC 17.
- **Settings**: Account section on top (email, Sign out, Delete account, Privacy policy); delete confirmation
  alert; delete error alert.

## Design note (design-lead, 2026-11-26)
Renders: `docs/design/renders/030c/` (`sheet-*.png` overviews; prototypes from the real DesignSystem components, light/dark/forest; glass is
hidden by the renderer; the alert and the web sheet are stand-ins for system UI). Apple components first; the only custom-drawn pieces are the logo and Google's button.

**`ContinueWithGoogleButton(isLoading:action:)`** (DesignSystem, done; gallery `gallery.google`). Checked against
developers.google.com/identity/branding-guidelines on 2026-11-26: approved text "Continue with Google", Google Sans
Medium (bundled 8 KB subset, OFL), the standard-colour "G" from Google's iOS asset bundle (unaltered, 20 pt), Google's
Light theme in light (white, 1 pt `#747775`, `#1F1F1F` text) and Dark theme in dark and forest (`#131314`,
`#8E918F`, `#E3E3E3`), pill, iOS padding 16/12/16, full width, 50 pt tall. Signing in: label stays, a `ProgressView`
at the trailing edge (no layout shift). Disabled: 38 % opacity. Use it as is: no tint, no glass, no restyling, no
other Google mark anywhere. If Sign in with Apple joins later (030 App Store note), it goes **above** with the same
width and height (Apple's `SignInWithAppleButton`, `.black`/`.white` by scheme), so neither outweighs the other.

**Sign-in screen** (`SignInView`, `.fullScreenCover`, `.interactiveDismissDisabled()`), `Theme.background` edge to
edge, side margins 24 (`Theme.Spacing.l`), no navigation bar, no toolbar:
```
            (flexible space)           the logo block is pinned (centred, 30 pt above the middle) in
                                       every state
          [LaCarteLogo 80 pt]          LaCarteLaunchMark on first appear (Reduce Motion: static)
                 16
            la-carte                   .screenTitle, ink          ─┐ one element for VoiceOver:
                 8                                                 │ "la-carte. Sign in to get your deck."
     Sign in to get your deck.         .body, secondaryInk        ─┘ (.isHeader on the title)
            (flexible space)
   [ G  Continue with Google ]         signIn.google
                 16
   This account can't be used yet.     signIn.error: .meta, ink (it must pass AA), centred, 2 lines
                                       max; reserves one line when empty so nothing moves
               Privacy                 signIn.privacy: .meta ink, its own line
                                       each button ≥ 44 pt tall (frame + contentShape)
```
- Messages go in the one `signIn.error` slot, ink, never red or pink: not allowed, unverified, failed, "You were
  signed out. Sign in again." (arriving after an expired session). A new tap clears it. `.sensoryFeedback(.error)`
  when a failure message appears; none on cancel (cancel = back to idle, no message).
- **No server UI** (user decision 2026-11-26): no host caption, no "Change", no URL field. "Privacy" is the only
  footer item (`signIn.privacy`, opens `<base>/privacy` with `openURL`, i.e. Safari).
- **Hand-off**: tapping the button starts `ASWebAuthenticationSession`; iOS presents its own sheet (host in the
  sheet's bar, Cancel top-left). We draw nothing over it and add no "Opening Google…" step; the button's spinner
  is the only progress, and stays until the session returns.
- **Signed in**: the cover dismisses with the system slide-down onto Study (already loading the deck);
  `.sensoryFeedback(.success)`. No welcome screen, no toast.

**Settings** (keeps `Form`, `Theme.surface` rows, `.tint(Theme.ink)`), sections top to bottom:
1. **Account**: the email row (`settings.account.email`: email `.body` ink, "Signed in with Google" `.meta`
   secondaryInk below; "Signed in" while `GET /me` loads or offline), "Access tokens" `NavigationLink`
   (`settings.tokens`, 030d; omit until 030d lands), "Sign Out" (`settings.signOut`, ink, no confirmation).
2. Appearance, Ask AI: unchanged. (The Server section is gone: no URL, no Test connection.)
3. Last section: "Privacy Policy" (`settings.privacy`, `Link`, trailing `arrow.up.right` in secondaryInk) and
   "Delete Account" (`settings.deleteAccount`, `Button(role: .destructive)`, system red), footer "Deletes your
   account, deck and reviews from the server." Delete sits apart from Sign Out so neither is tapped for the other;
   still one scroll away from the top (5.1.1(v): easy to find).
- Delete confirmation: system `.alert` as in decision 9, buttons "Cancel" (`.cancel`) and "Delete Account"
  (`.destructive`, `settings.deleteAccount.confirm`). While `DELETE /me` runs, the Delete row shows a trailing
  `ProgressView` and is disabled. Failure: `.alert("Couldn't delete your account. Try again.")` with "OK".
- After sign out / delete: Settings dismisses and the sign-in screen covers the app, idle, no message.

**Widget, signed out** (no `widget-token` or `api-token`): a new `.signedOut` content, small and medium alike,
leading-aligned like 007: `LaCarteLogo` 28 pt top-left, bottom-left "Sign in to see your streak" (`.body`
medium, ink, 2 lines max) over "Open la-carte" (`.meta`, secondaryInk). No grid, no today mark (so the logo's
line is the only pink). Tap opens the app (default `widgetURL`). Tinted/clear Home Screen: inks per 007 and
no logo (its colours don't survive tinting). VoiceOver: "Sign in to la-carte to see your
streak". "Can't reach your deck" stays for a network failure with a token.

## TCA shape (iOS)
- New module **`SignInFeature`** (child of `AppFeature`; deps `APIClient`, `DesignSystem`):
  - State: `status: Status` (`idle`, `signingIn`, `failed(Message)`), `Message` = `notAllowed | unverifiedEmail |
    failed | sessionExpired | noServer`. `AppFeature` presents it with `.noServer` when `apiClient.baseURL` is nil;
    the button is disabled while the message is `.noServer`.
  - Actions: `signInButtonTapped`, `signInResponse(Result<Void, SignInError>)`, `delegate(.signedIn)`.
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
- **`SettingsFeature`**: State drops `token`, `apiURL` and the connection test status; adds `email: String?`, `@Presents alert`. Actions add
  `signOutButtonTapped`, `deleteAccountButtonTapped`, `alert(.presented(.confirmDelete))`, `meResponse`,
  `deleteResponse`, `delegate(.signedOut)`; drops `urlChanged`, `tokenChanged`, the test-connection actions.
- `docs/architecture.md` (architect, done with this spec): module list, runtime configuration, Keychain items.

## API / MCP changes
None beyond 030a/030b. `APIClient` adds `Me`, `TokenResponse`, `PersonalToken` models + `DecodingTests`.

## Accessibility identifiers
- `signIn.google`: Continue with Google
- `signIn.error`: the error line
- `signIn.privacy`: privacy link
- `settings.account.email`: the signed-in email
- `settings.signOut`, `settings.deleteAccount`: buttons
- `settings.deleteAccount.confirm`: the alert's destructive button
- `settings.privacy`: privacy policy link
- `settings.tokens`: "Access tokens" row (030d)
- Removed: `settings.token`, `settings.token.reveal`, `settings.url`, `settings.test`, `settings.status` (and the
  earlier draft ids `signIn.server`, `signIn.serverURL`)

## Out of scope
- Sign in with Apple (030 App Store note). PAT management UI (030d). Universal-link callback / associated domains.
  Any in-app server choice (custom URL, "use your own server"): self-hosters build from source (030
  "Self-hosting"). Account switching. VoiceOver, Dynamic Type, localisation (per the user).
