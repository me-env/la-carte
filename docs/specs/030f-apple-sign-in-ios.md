# 030f — Sign in with Apple (iOS)

Status: ready
Owners: release-engineer (entitlement + capability, first) ∥ ios-engineer → code-reviewer → qa-validator;
design-lead checks the button placement against the 030c design note (already decided there)
Depends on: 030c (sign-in screen, `AuthClient`, session storage) merged or on the same branch; the 030e contract
(builds and tests on mock; ships after 030e is deployed with the Apple variables). Overview: [030](030-accounts-google-login.md).
Design reference: the 030c design note (Apple's button **above** Google's, same width and height);
Apple HIG "Sign in with Apple" buttons (developer.apple.com/design/human-interface-guidelines/sign-in-with-apple).


> **Amended by [032](032-encryption.md):** after `POST /oauth/apple` the app runs the same key step as the Google path
> (032c decision 1).
## Goal
The sign-in screen offers "Continue with Apple" as an equal option next to "Continue with Google" (guideline 4.8).
One Face ID confirmation, no browser sheet, then the user's deck. Settings says which provider the account uses.

## User stories
- As an iPhone user, I tap "Continue with Apple", confirm, and see my deck.
- As a user who hides my email, it still works; Settings shows the relay address Apple gave la-carte.
- As someone whose email already has a Google-backed account, I'm told to use Google instead, and nothing is created.

## Decisions
1. **Native, no web sheet**: `ASAuthorizationAppleIDProvider().createRequest()` with `requestedScopes = [.email]`
   (no `.fullName`), `nonce` = SHA-256 hex of a random 32-byte raw nonce (`SecRandomCopyBytes`), run by an
   `ASAuthorizationController` with the key window as presentation anchor. The credential's `identityToken` and
   `authorizationCode` (UTF-8) and the raw nonce go to `POST /oauth/apple` with `client_id=la-carte-ios` (030e).
   The `/token`-shaped reply is stored exactly like the Google path (Keychain `session`, then the widget `stats`
   token, then `api-token` deleted: 030c decisions 3, 5, 6).
2. **Errors**: `ASAuthorizationError.canceled` → `.cancelled` (back to idle, no message); `access_denied` with
   `use_google` → `.useGoogle`, `not_allowed` → `.notAllowed`; anything else (including `.failed`, `.unknown`,
   a missing token, `invalid_grant`, network) → `.failed`. 030c's Google path gains the mirror case: callback
   `error_description=use_apple` → `.useApple`.
3. **Messages** in the one `signIn.error` slot (030c design note): `.useGoogle` "This email already has an account.
   Use Continue with Google."; `.useApple` "This email already has an account. Use Continue with Apple." Others
   unchanged.
4. **Button**: Apple's `SignInWithAppleButton(.continue)` ("Continue with Apple"), `.signInWithAppleButtonStyle`
   `.black` in light and `.white` in dark and forest, the same width and 50 pt height as `ContinueWithGoogleButton`,
   corner radius matching its pill (`.clipShape(.capsule)`), 12 pt above it. The button's own request/completion
   closures are not used: it is drawn inside a plain `Button` (hit testing off on the Apple view) that sends
   `appleButtonTapped`, so the logic stays in `AuthClient` and is testable. While either provider is signing in,
   both buttons are disabled and the spinner shows only in the tapped one (the Apple button gets a trailing
   `ProgressView` overlay in its label colour).
5. **Settings**: the email row's caption reads "Signed in with Apple" / "Signed in with Google" from `Me.provider`
   (`null` → "Signed in"). Nothing else changes; Sign out and Delete Account work the same (the server revokes Apple
   on delete, 030e).
6. **Entitlement** (release-engineer): `com.apple.developer.applesignin = ["Default"]` in the app's entitlements
   only (not the widget); the App ID needs the Sign in with Apple capability (030 "What the user provides"; automatic
   signing with an Admin key may add it, otherwise the user enables it once). The Ad Hoc and future App Store
   profiles must carry it: `ci/verify-ipa.sh` checks the entitlement is in the signed app.
7. **Mock**: `LA_CARTE_AUTH=signed-out` → Apple sign-in succeeds after 0.3 s like Google (`me.provider = "apple"`);
   `LA_CARTE_AUTH=use-google` → Apple fails with `.useGoogle`. No Apple sheet in mock modes (UI tests never see
   system UI).

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Signed out (mock), the sign-in screen shows `signIn.apple` above `signIn.google`, same width and height | UI |
| 2 | Tapping `signIn.apple` shows progress in that button, disables `signIn.google`, then the cover goes away and Study shows the mock deck | both |
| 3 | `LA_CARTE_AUTH=use-google`: tapping `signIn.apple` shows `signIn.error` "This email already has an account. Use Continue with Google." and stays | both |
| 4 | `SignInFeature`: `.cancelled` from Apple → idle with no message; `.failed` → "Couldn't sign in. Try again."; `.useApple` (Google path) → its message; a tap on either button while signing in does nothing | unit |
| 5 | Live `AuthClient.signInWithApple` (injected authorization closure + URLProtocol stub): requests scope email only (no full name), sends to Apple the SHA-256 hex of the raw nonce it later posts to `/oauth/apple`, posts `client_id=la-carte-ios`, `identity_token`, `authorization_code`, `nonce` form-encoded, stores the session, mints the widget token, deletes `api-token` | unit |
| 6 | Live client: a 400 `{error: "access_denied", error_description: "use_google"}` → `.useGoogle`; `invalid_grant` → `.failed`; a credential without `identityToken` → `.failed` with no request sent | unit |
| 7 | Settings shows "Signed in with Apple" under `settings.account.email` when `me.provider == "apple"`, "Signed in with Google" for `google`, "Signed in" for `null` | both |
| 8 | `DecodingTests`: `Me` with `provider` `"apple"`, `"google"` and `null` | unit |
| 9 | The signed Ad Hoc app carries `com.apple.developer.applesignin` (`ci/verify-ipa.sh` passes) | CI |
| 10 | Screenshots, light + dark: `signin-idle` (both buttons), `signin-use-google`, `settings-account-apple` | UI |
| 11 | On the iPhone against the deployed server: "Continue with Apple" with Hide My Email creates an account and shows an empty deck; Settings shows the relay email and "Signed in with Apple"; Delete Account returns to the sign-in screen (manager with the user) | manual |

## Screens & states
- **Sign in**: idle with both buttons; Apple signing in; Google signing in; error line (030c states + `useGoogle`,
  `useApple`). Screenshots in AC 10.
- **Settings**: account caption per provider.

## TCA shape (iOS)
- `SignInFeature` (030c): Actions add `appleButtonTapped`; `signInResponse` carries which provider ran (`State`
  gains `activeProvider: Provider?`, `Provider = apple | google`, for the spinner). `Message` adds `useGoogle`,
  `useApple`.
- `AuthClient` adds `signInWithApple() async throws(SignInError)`; `SignInError` adds `useGoogle`, `useApple`. Live:
  nonce + `ASAuthorizationController` behind a small `AppleAuthorization` closure (tests inject the credential
  fields) + `POST /oauth/apple` + the shared "store session" path of 030c.
- `SettingsFeature`: no new state (`Me.provider` drives the caption).
- No new module, no new dependency.

## API / MCP changes
None beyond 030e. `APIClient`: `Me.provider: String?`.

## Accessibility identifiers
- `signIn.apple`: Continue with Apple
- (existing) `signIn.google`, `signIn.error`, `signIn.privacy`, `settings.account.email`

## Out of scope
- Checking `getCredentialState` at launch and Apple's server-to-server notifications (backlog). Requesting the
  name. Linking Apple and Google. Apple sign-in in the widget (it only reads the `stats` token).
