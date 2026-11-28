# Release: TestFlight and the App Store

Owner: `release-engineer`. This is the checklist for going from today's Ad Hoc builds (`docs/release.md`) to
TestFlight (a small group of friends as **external testers**) and then App Store review. It's an audit, written
2026-11-25 and updated 2026-11-28 for the user's App Store decisions: nothing here has been done in the Apple
account yet. Apple requirements were checked that day on
developer.apple.com (links next to each item). Out of scope for now: VoiceOver, Dynamic Type, localisation.

Status: **done**, **missing** (an agent can do it), **needs the user** (Apple account, App Store Connect,
legal answers; the smallest action is given).

## User decisions this checklist follows

- **No passwords, ever.** Sign-in is OAuth only.
- **Sign in with Apple next to Google** (2026-11-28, guideline 4.8): specs 030e (server), 030f (app), 030g (agents
  on the web, not a blocker).
- **Account deletion in the app** deletes everything and revokes the Apple and Google grants (030a, 030c, 030e).
- **Privacy policy, support page and a minimal landing page** are served by the API on its domain (030h).
- **Open sign-up by default** (`LA_CARTE_SIGNUP=open`): App Review uses the App Store build with its own Apple ID;
  no demo account.
- **App Store Connect setup is the user's job** when the build is ready; this checklist is what they follow.

## Top blockers, in order

1. **Accounts (spec 030: 030a, 030b, 030c, 030e, 030f).** Today the app is bring-your-own-server: one deck, one
   bearer token (`BearerTokenMiddleware`, `api/src/la_carte_api/app.py`), URL and token typed in Settings. A friend
   or a reviewer can't use that. TestFlight for friends and App Review both need a hosted, multi-user server with
   Sign in with Apple and Google, open sign-up, and **in-app account deletion**.
2. ~~**No privacy manifest** for the app or the widget.~~ Fixed: both have one. App Store Connect has refused uploads without one since
   2024-05-01, so this blocks every upload, internal TestFlight included.
3. **No App Store Connect app record.** The user creates it, with the Account Holder, Admin or App Manager role.
4. **CI key role.** Cloud signing for App Store distribution needs an **Admin** key. It's the same issue that broke
   Ad Hoc export in CI on 2026-11-21 (`docs/release.md`, one-time setup step 3).
5. **No privacy policy or support URL.** Both are needed for App Store review: specified in 030h
   (`<PUBLIC>/privacy`, `<PUBLIC>/support`), waiting on the support email. External TestFlight needs a feedback
   email and a beta description.

## Checklist

### Identity and signing

| Item | Status | Notes / smallest action |
|---|---|---|
| Team and bundle IDs | **done** | Team and prefix from `ios/Config/Signing.xcconfig` (`docs/release.md`). App `fr.lacarte.app`, widget `fr.lacarte.app.widget`, App Group `group.fr.lacarte.app`. The app ID exists on the team (Ad Hoc build signed and installed on 2026-11-21). The widget ID and the App Group follow the spec 007 one-time steps in `docs/release.md`. |
| Sign in with Apple capability | **missing** (030f) / **needs the user** | Entitlement `com.apple.developer.applesignin` in the app (release-engineer, 030f). The App ID needs the capability ("Enable as a primary App ID"); automatic signing with an Admin key may add it, otherwise the user does it once, plus a Sign in with Apple **key** (.p8) for the server (spec 030 "What the user provides" 4). Profiles regenerate after the change. |
| App Store Connect app record | **needs the user** | App Store Connect → Apps → + → New App: platform iOS, name (must be unique on the store; "la carte" may be taken, so have a fallback such as "la carte: flashcards"), primary language English, bundle ID `fr.lacarte.app`, SKU (any string, e.g. `lacarte-ios`), User Access Full. Role: Account Holder, Admin or App Manager. The Account Holder must first accept the latest agreements (Business → Agreements). [Add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app) |
| Apple Distribution certificate | **done (Mac)** / **needs the user (CI)** | Already exists from the Ad Hoc setup (same certificate for Ad Hoc and App Store). For CI, cloud signing needs an **Admin**-role API key (or a user with "Access to Cloud Managed Distribution Certificate"). Smallest action: App Store Connect → Users and Access → Integrations → change the existing key's role to Admin, or create a new Admin key and update the `prod` secret ([WWDC21 10204](https://developer.apple.com/videos/play/wwdc2021/10204/)). |
| App Store provisioning profiles (app + widget) | **missing (automatic)** | Nothing to commit. `-allowProvisioningUpdates` with an Admin key or the Xcode account creates "iOS Team Store Provisioning Profile" for both bundle IDs, with the App Group, on the first `app-store-connect` export. |
| App Group on the App Store profiles | **done once Ad Hoc works with the widget** | App Store profiles pick up the group from the App IDs, so the spec 007 registration (`docs/release.md`) covers both. Not re-checked in the portal for this audit. |

### Build and versioning

| Item | Status | Notes / smallest action |
|---|---|---|
| Minimum SDK | **done** | Since 2026-04-28, uploads must be built with Xcode 26+ and the iOS 26 SDK. The `macos-26` runner (Xcode 26.x) and the Mac (Xcode 27.2) both qualify. [Upcoming requirements](https://developer.apple.com/news/upcoming-requirements/) |
| Version (`CFBundleShortVersionString`) | **done** | From the `v*` tag in CI (`v0.1.0` → `0.1.0`). Every TestFlight or App Store build needs a real tag: the untagged `0.0.<run>` versions are fine for Ad Hoc but not for uploads. There are no tags yet. |
| Build number (`CFBundleVersion`) | **missing** | Each upload needs a unique build number for its version: digits and up to three dot-separated integers ([CFBundleVersion](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion)). Ad Hoc uses the Ad Hoc workflow's `run_number`. The TestFlight workflow should use **its own** `run_number`, the only builds App Store Connect sees, so numbers only go up. Set `manageAppVersionAndBuildNumber = NO` in ExportOptions so Xcode doesn't rewrite it and the .ipa matches the logs. |
| Export compliance (`ITSAppUsesNonExemptEncryption`) | **done** | The app only uses OS encryption (HTTPS via URLSession, Keychain; Google OAuth over HTTPS). Apple: that "is exempt from export documentation upload requirements". `ITSAppUsesNonExemptEncryption = NO` is in the app and widget Info.plist (`ios/Config/`), so App Store Connect stops showing "Missing Compliance" and asking on every build. France also controls encryption apps, but its categories (secure storage or communications, anti-virus) don't fit a flashcard app; Apple points to ANSSI. That's our reading, so the user confirms it once by answering the questionnaire. [Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations), [Export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance) |
| ATS exception | **done** | `NSAllowsLocalNetworking` (local dev/E2E only) is a narrow exception that needs no justification. Once accounts point at a fixed HTTPS server, consider dropping it from Release. |

### Privacy

| Item | Status | Notes / smallest action |
|---|---|---|
| `PrivacyInfo.xcprivacy` for the app | **done** (`ios/LaCarte/PrivacyInfo.xcprivacy`) | "Apps that don't describe their use of required reason API in their privacy manifest file aren't accepted by App Store Connect" (since 2024-05-01). The app uses `UserDefaults` (standard: Settings, Study, `@Shared(.appStorage)`) and the App Group suite (`AppGroup.swift`, `TokenStore.swift`). Declare `NSPrivacyAccessedAPICategoryUserDefaults` with **CA92.1** (app-only defaults) and **1C8F.1** (App Group defaults), `NSPrivacyTracking = false`, and `NSPrivacyCollectedDataTypes` matching the App Privacy answers below. No file-timestamp, boot-time or disk-space APIs found in `ios/LaCarteKit/Sources`. Keychain isn't a required-reason API. TCA and swift-sharing ship their own manifests. Owner: ios-engineer (new resource in `ios/LaCarte/`). [Required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) |
| `PrivacyInfo.xcprivacy` for the widget | **done** (`ios/LaCarteWidget/PrivacyInfo.xcprivacy`) | The widget is its own executable and reads the App Group defaults (`DeckWidgetProvider`), so it needs its own manifest with **1C8F.1**. Apple says "each executable", not "extensions" by name, so this is our reading; it costs nothing. |
| App Privacy answers (App Store Connect) | **needs the user** (agent drafts) | "Collected" means sent off the device and kept longer than needed to serve the request. Once accounts exist, everything below goes to the developer's server, so it counts as collected and **linked to the user**. **Not used for tracking** (no ads, no data brokers). Expected answers: **Email Address** only, never a name (Google asks for openid + email only, Apple for email only, possibly a Hide My Email relay; App Functionality); **User ID** (App Functionality); **Product Interaction**: card shown, revealed, rated, app foreground (spec 029 activity log, App Functionality, plus Analytics if it's used for debugging feedback); **Other Diagnostic Data**: `api_error`, `photo_failed`, app and OS version (App Functionality); **Other User Content**: the cards and notes themselves (App Functionality). No crash or performance data unless added. Smallest action: the user pastes the agent's draft into App Store Connect → App Privacy. [App privacy details](https://developer.apple.com/app-store/app-privacy-details/) |
| Activity log (spec 029) | **done** (built) | Its rules (no free text, ids/enums/counts only) fit the answers above. The 90-day retention is stated in `/privacy` (030h), and its rows are deleted with the account (030a). |
| Privacy policy URL | **specified** (030h) / **needs the user** | Required in App Store Connect (App Privacy) and **inside the app**, easy to find (guideline 5.1.1(i)). `<PUBLIC>/privacy`, served by the API; the text is drafted in spec 030h and must match `PrivacyInfo.xcprivacy`. Linked from the sign-in screen and Settings (030c). Smallest action: approve the text and give the support email. |
| Support URL | **specified** (030h) / **needs the user** | Required. It "must lead to actual contact information" ([platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)). `<PUBLIC>/support` shows `LA_CARTE_SUPPORT_EMAIL`. Smallest action: choose the contact email. |
| Marketing URL | **specified** (030h) | Optional field: `<PUBLIC>/`, the landing page (screenshots, demo videos, App Store badge once `LA_CARTE_APP_STORE_URL` is set). |

### Accounts and review access (spec 030)

| Item | Status | Notes / smallest action |
|---|---|---|
| Hosted multi-user server | **missing** (030a, 030b) | The current server has one deck behind one token. Friends and the reviewer need their own decks on the hosted API. |
| Sign in with Apple and Google, no passwords | **missing** (030b, 030c, 030e, 030f) | OAuth only (user decision). The Google client secret and the Apple key stay in Dokploy env, out of git. |
| Open sign-up | **specified** (030b) | `LA_CARTE_SIGNUP=open` is the default; it must stay open for review (a reviewer's Apple ID, often a Hide My Email address, can't be allowlisted). |
| In-app account deletion | **specified** (030a, 030c, 030e; App Store blocker until built) | Guideline 5.1.1(v): apps that create accounts "must also let people initiate deletion of their account within the app"; deactivation alone "is insufficient". It must delete the deck, review logs, notes, activity events and feedback, and say how long that takes if it isn't immediate. A link to a web page that finishes the deletion is allowed. Revoking the Google grant is good practice. Sign in with Apple tokens are revoked through Apple's REST API on deletion (030e); Google's access token is revoked right after each sign-in, so no Google grant is left. Deletion is immediate; backups age out within 30 days (said in `/privacy`). [Offering account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/) |
| Reviewer demo account | **not needed** | Decision 2026-11-28: the reviewer uses the App Store build and signs in with their own Apple ID (open sign-up), getting an empty deck. In App Store Connect → App Review Information, leave "Sign-in required" unchecked or explain in the notes that Sign in with Apple creates an account. If review asks for a demo account anyway, fall back to a dedicated Google account seeded with marketing's demo deck. |
| Review notes | **missing** (agent drafts) | Up to 4000 bytes: what the app does; "Sign in with Apple (or Google) creates a free account; there is no demo account"; how to add a first card (Deck → +) and study it; account deletion in Settings → Delete Account; that the MCP server and "Ask AI" are optional extras; that the widget needs a signed-in app. |

### Guideline 4.8 (Sign in with Apple)

**Status: decided 2026-11-28: Sign in with Apple next to Google** (specs 030e, 030f; 030g for agents on the web).

What the guideline says (checked 2026-11-25, [App Review Guidelines 4.8](https://developer.apple.com/app-store/review/guidelines/)):
an app that uses a third-party login service such as Google to set up or authenticate the user's primary account
"must also offer as an equivalent option another login service" that limits data collection to name and email,
lets users keep their email private, and doesn't collect app interactions for advertising without consent. Sign in
with Apple meets all three. None of the exceptions fits la-carte.

What it takes: the capability on the App ID and the entitlement (030f, release-engineer), a Sign in with Apple key
for the server (Dokploy env), server-side identity token validation against Apple's JWKS and token revocation on
account deletion (030e). Apple's button sits above Google's, same size (030c design note).

### Store listing and assets

| Item | Status | Notes / smallest action |
|---|---|---|
| App icon | **done** | `AppIcon.appiconset`: light, dark and tinted 1024×1024, no alpha (checked with `sips`). design-lead may move to an Icon Composer icon later (HIG recommendation, not required). |
| Launch screen | **done** | `INFOPLIST_KEY_UILaunchScreen_Generation = YES` (generated launch screen). Nothing else required. |
| Screenshots | **missing** | iPhone only (`TARGETED_DEVICE_FAMILY = 1`). Upload the large Dynamic Island set (6.9", e.g. 1320×2868 portrait); smaller sizes are scaled from it. Then the 6.5" set isn't required. 1 to 10 PNG/JPEG, no alpha. Owner: marketing (demo deck, simulator `iPhone 17 Pro Max`), light mode, no real URLs or tokens. [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) |
| Name, subtitle, description, keywords, category | **needs the user** (marketing drafts) | Category: Education. |
| Age rating | **needs the user** | Answer the updated questionnaire (tiers 4+, 9+, 13+, 16+, 18+; the new questions had a 2026-01-31 deadline). Expected answers: no user-generated content shared with others (each deck is private), no messaging, no ads. "Unrestricted web access": no, because "Ask AI" opens the AI site or app outside la-carte and there's no in-app browser. Likely **4+**. [Age ratings](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions) |
| Copyright, contact for App Review | **needs the user** | Name, email and phone for App Review ([App Review information](https://developer.apple.com/help/app-store-connect/reference/app-review-information)). |

### TestFlight (external testers)

| Item | Status | Notes / smallest action |
|---|---|---|
| Internal group | **needs the user** | An internal group must exist before an external one. The user alone is enough. [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers) |
| Test Information | **needs the user** (agent drafts) | Beta App Description (required), feedback email, contact info, and sign-in details (none needed: Sign in with Apple creates an account, see "Reviewer demo account") for TestFlight App Review. [Provide test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information) |
| External group and public link | **needs the user** | Up to 10,000 external testers; the public link can be capped (e.g. 20). The first build goes through TestFlight App Review; later builds may not. Builds expire after **90 days**. Testers can't be paid or rewarded (guideline 2.2). |
| Export compliance answered | **done** | Covered by `ITSAppUsesNonExemptEncryption = NO` (above). Otherwise each build shows "Missing Compliance". |

## CI: TestFlight builds next to Ad Hoc

Proposed (not implemented yet; release-engineer does it once the app record exists and the key is Admin):

- **Same entry points, one new method.** `ci/archive.sh` stays as it is. `ci/export-ipa.sh` takes
  `EXPORT_METHOD=adhoc|appstore` (default `adhoc`) and picks `ios/Config/ExportOptions-AdHoc.plist` or a new
  `ExportOptions-AppStore.plist`:
  `method = app-store-connect`, `destination = upload`, `signingStyle = automatic`,
  `manageAppVersionAndBuildNumber = NO`, `uploadSymbols = YES`, `testFlightInternalTestingOnly = NO`
  (all keys checked in `xcodebuild -help`, Xcode 27.2). `teamID` is added from `Signing.xcconfig` as today. The
  export signs with the App Store profiles and uploads in the same `xcodebuild -exportArchive` call, with the
  same `auth_flags` (API key in CI, Xcode account on the Mac). No altool or Transporter step and no extra secret.
- **Local entry point:** `scripts/ios-testflight.sh` (archive + upload), the twin of `scripts/ios-adhoc.sh`, so a
  CI failure reproduces on the Mac.
- **Workflow** `.github/workflows/testflight.yml`: `workflow_dispatch` (a `v*` tag picked in the UI), environment
  `prod`, same secret `AC_API_KEY_BASE64` and variables `ASC_KEY_ID`/`ASC_ISSUER_ID`. `VERSION` comes from the
  tag and `BUILD_NUMBER` from this workflow's `run_number`. Same "Remove API key" `always()` step and no `set -x`.
  It runs `ci/verify-ipa.sh` adapted for App Store profiles (no device list) on an exported copy, or skips it for
  uploads. Keep tag pushes on Ad Hoc only until the friends group is set up; then a tag can trigger both.
- **Key role:** uploading only needs Developer, but **cloud signing for App Store distribution needs Admin** (or
  per-user "Access to Cloud Managed Distribution Certificate"). One Admin key covers Ad Hoc and TestFlight.
  [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- After the upload, App Store Connect processes the build (a few minutes or more). Distribution to the external
  group stays a manual click in App Store Connect at first. Automating it (App Store Connect API `betaGroups`)
  can wait.

## User actions, smallest first

The accounts-side values (support email, Google client, Apple key and capability, Dokploy env, repo variable) are
one consolidated list in spec 030, "What the user provides"; the manager asks for it once. App Store Connect
actions, when the build is ready:

1. Make the CI API key **Admin** (App Store Connect → Users and Access → Integrations). This also fixes Ad Hoc CI.
2. Accept the agreements and **create the app record** (fields above).
3. Approve the drafted App Privacy answers, age rating, review notes and Test Information, and paste them into
   App Store Connect; Privacy Policy URL `<PUBLIC>/privacy`, Support URL `<PUBLIC>/support`, Marketing URL
   `<PUBLIC>/`.
4. Once the app is live: set `LA_CARTE_APP_STORE_URL` in Dokploy so the landing page shows the badge.
