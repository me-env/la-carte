# Release: getting la-carte onto the iPhone

Owner: `release-engineer` agent. Ad Hoc builds: a signed .ipa that installs on the iPhones registered
on your Apple Developer team. This page uses this project's values (team `5X9ZWT7KT3`, bundle ID
`fr.lacarte.app`); with your own team, read them as yours (see "Your own team" below).

## Your own team (forks)

You need a paid Apple Developer account. Locally, no tracked file needs editing:

1. `cp ios/Config/Signing.local.xcconfig.example ios/Config/Signing.local.xcconfig` (gitignored) and set
   `DEVELOPMENT_TEAM` (your team ID) and `LA_CARTE_BUNDLE_ID_PREFIX` (a reverse-DNS name you own). The app
   becomes `<prefix>.app`, the UI tests `<prefix>.app.uitests`.
2. Follow "One-time setup" and "First run" below with your team ID and your iPhone's UDID.
3. For CI on your fork: the `prod` environment secret `AC_API_KEY_BASE64` (your key), and the variables
   `ASC_KEY_ID` / `ASC_ISSUER_ID` (`gh variable set ASC_KEY_ID --env prod --body <KEY_ID>`). CI checks out
   the repo, so the gitignored local file isn't there: commit your values in `ios/Config/Signing.xcconfig`
   on your fork instead.

Where each value comes from:

| Value | Source | Used by |
|---|---|---|
| Team ID | `ios/Config/Signing.xcconfig`, overridden by `Signing.local.xcconfig` | Xcode targets (base configuration), `ci/_env.sh` → `ci/archive.sh`, `teamID` added to ExportOptions by `ci/export-ipa.sh` |
| Bundle ID prefix | same files, `LA_CARTE_BUNDLE_ID_PREFIX` | `PRODUCT_BUNDLE_IDENTIFIER` of both targets; `scripts/ios-install-device.sh` reads the bundle ID from the .ipa |
| API key ID / issuer | env `ASC_KEY_ID` / `ASC_ISSUER_ID` (CI: GitHub variables), defaults in `ci/_env.sh` are this project's key | `auth_flags` in `ci/_env.sh` |

Simulator builds and tests (`scripts/ios-build.sh`, `ios-test.sh`, `ios-ui-test.sh`, CI) don't need an Apple
account or a valid team: the simulator signs locally. To check the device build and its bundle ID without
signing:
```bash
xcodebuild archive -project ios/LaCarte.xcodeproj -scheme LaCarte -configuration Release \
  -destination generic/platform=iOS -archivePath build/unsigned.xcarchive -skipMacroValidation CODE_SIGNING_ALLOWED=NO
plutil -extract CFBundleIdentifier raw build/unsigned.xcarchive/Products/Applications/LaCarte.app/Info.plist
```

Spec 007 (widget) extends the same scheme: the extension is `$(LA_CARTE_BUNDLE_ID_PREFIX).app.widget` and the
App Group `group.$(LA_CARTE_BUNDLE_ID_PREFIX).app`, both from the xcconfig (entitlements files expand build
settings). `Signing.xcconfig` defines `LA_CARTE_APP_GROUP = group.$(LA_CARTE_BUNDLE_ID_PREFIX).app`, used by
`Config/LaCarte.entitlements`, `Config/LaCarteWidget.entitlements` and the `LaCarteAppGroup` key of both Info.plists
(read by `AppGroup.id`; nothing is hard-coded). The Ad Hoc build signs **two** bundle IDs (app + widget), both
with that App Group; the App Group also serves as the token's keychain access group (no Keychain Sharing
capability). Automatic signing with `-allowProvisioningUpdates` should register the widget App ID, the App Group
and both profiles; if the API key can't create the App Group, create it once at developer.apple.com
(Identifiers → App Groups) and enable it on both App IDs.

## How it works

```
git tag v0.1.0 && git push --tags
        │
        ▼
GitHub Actions "iOS Ad Hoc" (.github/workflows/adhoc.yml, macos-26, environment: prod)
  ci/archive.sh     xcodebuild archive, automatic signing via the App Store Connect API key
  ci/export-ipa.sh  export method release-testing (= Ad Hoc) → build/export/LaCarte.ipa
  ci/verify-ipa.sh  codesign OK, Ad Hoc profile, lists the device UDIDs it can install on
        │  artifact "la-carte-ipa" + GitHub Release asset
        ▼
scripts/ios-install-device.sh   downloads the latest .ipa (gh) → xcrun devicectl install → launch
```

There's no .p12 or provisioning profile to manage. With `-allowProvisioningUpdates`, Xcode creates or
downloads the Apple Distribution certificate and an Ad Hoc profile ("iOS Team Ad Hoc Provisioning
Profile: <bundle ID>") containing **every device registered on the team**. Both are valid
about **one year**; after that, re-run a build and Xcode renews them.

Two ways to sign, chosen by `auth_flags` in `ci/_env.sh`:

| Where | Auth | Needs |
|---|---|---|
| CI | API key (`AC_API_KEY_BASE64`) | key with the **Admin** role, or "Access to Cloud Managed Distribution Certificate" |
| Mac, no key set | the account signed in to Xcode | a local "Apple Distribution: … (<TEAM_ID>)" certificate in the keychain |

CI never falls back to the Xcode account: if `CI` is set and the secret is missing, the job fails.
With a key, xcodebuild uses the key's role and ignores the local certificate.

`CI` (`.github/workflows/ci.yml`) runs on every PR and push to main: API tests, the API Docker image build (`docs/deploy.md`), iOS unit tests, UI tests
(mock deck), and live E2E. Before the UI tests, `ci/boot-simulator.sh` boots the simulator and switches its
appearance once with `simctl ui` (otherwise `XCUIDevice.shared.appearance` had no effect on the macos-26 runner and
every dark screenshot was light). Screenshots are uploaded as the `screenshots` artifact.

## One-time setup

1. **Register the iPhone** on your team (developer.apple.com → Devices) with its UDID (Finder → the
   iPhone → click the line under its name, or Xcode → Devices). Ad Hoc builds only install on registered devices.
   Opening the project in Xcode with the phone connected and building to it also registers it.
2. **GitHub repo** with an environment named `prod` holding the secret `AC_API_KEY_BASE64`, your App Store
   Connect API key: `base64 -i AuthKey_<KEY_ID>.p8 | gh secret set AC_API_KEY_BASE64 --env prod`.
   Key ID and issuer: defaults in `ci/_env.sh` (this project's), or the `ASC_KEY_ID` / `ASC_ISSUER_ID`
   variables (they're identifiers, not secrets).
3. For CI, the API key needs the **Admin** role (or "Access to Cloud Managed Distribution Certificate").
   Found on 2026-11-21: with a key without it, archive succeeds but export fails with
   "Cloud signing permission error: You haven't been given access to cloud-managed distribution
   certificates" and "No profiles for '<bundle ID>' were found". A local Apple Distribution
   certificate doesn't help there. Change the key's role in App Store Connect → Users and Access →
   Integrations, or make a new key with that access.
4. Developer Mode must be on on the iPhone (Settings → Privacy & Security), for both Ad Hoc and dev installs.

## First run (needs you)

Run these once on the Mac, with the iPhone unlocked and paired (USB or same Wi-Fi). They touch your
Apple account, so no agent runs them for you. This is what worked on 2026-11-21.

1. In Xcode → Settings → Accounts → your team → Manage Certificates, create an
   **Apple Distribution** certificate (once, valid about a year).
2. Plug in the iPhone (Developer Mode on, see one-time setup step 4).
   It must be registered on the team (one-time setup step 1).
3. Build the signed Ad Hoc .ipa with the Xcode account (no API key):
   ```bash
   scripts/ios-adhoc.sh
   ```
   It should end with `✓ Ad Hoc profile '…' for N device(s):`, followed by your iPhone's UDID. If the UDID
   is missing, the phone isn't registered: register it and re-run.
4. Install and launch it:
   ```bash
   scripts/ios-install-device.sh build/export/LaCarte.ipa
   ```
   The first launch of an Ad Hoc build may ask you to trust the developer: on the iPhone, Settings →
   General → VPN & Device Management.
5. For CI: one-time setup steps 2 and 3 (the `prod` secret, an Admin-role key), then tag as below.

Verified 2026-11-21: signed with the Xcode account, `ci/verify-ipa.sh` passed, installed and launched on
the iPhone. (That run showed version 0.0.0; local builds now default to the latest `v*` tag, else 0.1.0.)

## Everyday

| I want to… | Run |
|---|---|
| ship a build to my phone | `git tag v0.1.0 && git push --tags`, then `scripts/ios-install-device.sh` |
| rebuild without a tag | Actions → iOS Ad Hoc → Run workflow |
| build the .ipa locally | `scripts/ios-adhoc.sh` (Xcode account) |
| reproduce CI signing locally | `AC_API_KEY_PATH=…/AuthKey_<KEY_ID>.p8 ASC_KEY_ID=… ASC_ISSUER_ID=… scripts/ios-adhoc.sh` |
| install a local .ipa | `scripts/ios-install-device.sh build/export/LaCarte.ipa` |
| debug on device | open `ios/LaCarte.xcodeproj`, choose the iPhone, Run |

Versioning: in CI, `MARKETING_VERSION` comes from the tag (`v1.2.0` → `1.2.0`, untagged runs `0.0.<run>`);
the build number is the workflow run number. Locally, `VERSION` defaults to the latest `v*` tag (else
`0.1.0`) and the build number to a timestamp; override with `VERSION=… BUILD_NUMBER=…`.

The deployment target is **iOS 26.0**, so the app builds with Xcode 26.x (what the `macos-26` runner has,
up to 26.6) as well as Xcode 27 (the Mac). Both workflows use `setup-xcode` with `latest-stable`, the newest
non-beta Xcode on the image, and pick Xcode 27 automatically once the image ships it. Keep the project
format at `objectVersion = 77` (Xcode 16 format) so Xcode 26 can open it. If Xcode 27 on the Mac bumps it
to 90 when saving the project, set it back.

## The API the phone talks to
The simulator reaches `127.0.0.1:8000` on the Mac, but a phone can't. Deploy the API with HTTPS
(`docs/deploy.md`; any Docker host behind an HTTPS reverse proxy works) and enter its URL and token in the app's Settings screen (spec 003, backlog #5).
