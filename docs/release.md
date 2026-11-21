# Release: getting la-carte onto the iPhone

Owner: `release-engineer` agent. Ad Hoc builds: a signed .ipa that installs on the iPhones registered
on your Apple Developer team. This page uses this project's values (team `5X9ZWT7KT3`, bundle ID
`fr.lacarte.app`); with your own team, read them as yours (see "Your own team" below).

## Your own team (forks)

You need a paid Apple Developer account. Locally, no tracked file needs editing:

1. `cp ios/Config/Signing.local.xcconfig.example ios/Config/Signing.local.xcconfig` (gitignored) and set
   `DEVELOPMENT_TEAM` (your team ID) and `LA_CARTE_BUNDLE_ID_PREFIX` (a reverse-DNS name you own). The app
   becomes `<prefix>.app`, the widget `<prefix>.app.widget`, the UI tests `<prefix>.app.uitests`, and the
   App Group shared by the app and the widget (settings, cached stats, and the token's keychain access group)
   `group.<prefix>.app`. The same prefix drives all four, so nothing else to rename.
2. Follow "One-time setup" and "First run" below with your team ID and your iPhone's UDID.
3. For CI on your fork: the `prod` environment secret `AC_API_KEY_BASE64` (your key), and the variables
   `ASC_KEY_ID` / `ASC_ISSUER_ID` (`gh variable set ASC_KEY_ID --env prod --body <KEY_ID>`). CI checks out
   the repo, so the gitignored local file isn't there: commit your values in `ios/Config/Signing.xcconfig`
   on your fork instead.

Where each value comes from:

| Value | Source | Used by |
|---|---|---|
| Team ID | `ios/Config/Signing.xcconfig`, overridden by `Signing.local.xcconfig` | Xcode targets (base configuration), `ci/_env.sh` → `ci/archive.sh`, `teamID` added to ExportOptions by `ci/export-ipa.sh` |
| Bundle ID prefix | same files, `LA_CARTE_BUNDLE_ID_PREFIX` | `PRODUCT_BUNDLE_IDENTIFIER` of every target, the App Group in `ios/Config/*.entitlements` (Xcode expands build settings there); `ci/verify-ipa.sh` checks the bundle IDs and the group against it; `scripts/ios-install-device.sh` reads the bundle ID from the .ipa |
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
settings). The Swift code must not hard-code `group.fr.lacarte.app`: read it at runtime (e.g. an Info.plist key
set to `group.$(LA_CARTE_BUNDLE_ID_PREFIX).app`).

### Widget signing (spec 007): register the App Group once

What automatic signing does and doesn't do, from Apple's docs (checked 2026-11-21):

- `xcodebuild -allowProvisioningUpdates`: "For automatically signed targets, xcodebuild will create and update
  profiles, app IDs, and certificates" (`xcodebuild -help`). So the widget App ID `<prefix>.app.widget` and its
  Ad Hoc profile are created on the first signed build. ExportOptions needs nothing per target
  (`provisioningProfiles` is for manual signing only).
- App Groups on iOS "need to be registered" ([Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)),
  and [registering one](https://developer.apple.com/help/account/identifiers/register-an-app-group) requires
  **Account Holder or Admin**, in the portal or with the + of the App Groups capability in Xcode. Apple doesn't
  document xcodebuild registering a group that only appears in an `.entitlements` file, and the App Store
  Connect API has no app-group resource at all (`bundleIdCapabilities` can switch on `APP_GROUPS`, not
  register or assign a group). So **neither the Mac build nor CI's key can be relied on to create the group.**

One-time, per team (a fork does the same with its own prefix), before the first signed widget build:

1. developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → + → **App Groups** →
   description "la carte", identifier `group.fr.lacarte.app` (`group.<prefix>.app` for a fork).
   (Equivalent: open the project in Xcode, LaCarte target → Signing & Capabilities → App Groups → +, same name.)
2. Run `scripts/ios-adhoc.sh` on the Mac (Xcode account, Admin). It creates the widget App ID and the two Ad Hoc
   profiles; `ci/verify-ipa.sh` fails with "profile doesn't include App Group" if the group isn't assigned to
   an App ID. If so, in Identifiers → `fr.lacarte.app` and `fr.lacarte.app.widget` → App Groups → Configure,
   tick the group, save, and re-run.
3. CI: the key already needs Admin for cloud signing (one-time setup step 3). Per Apple's
   [roles](https://developer.apple.com/help/account/access/roles/), registering App IDs and creating
   distribution profiles also need Admin (or App Manager with Certificates, Identifiers & Profiles access).
   A Developer-role key can't create Ad Hoc profiles; expect the same export failure as for the app on
   2026-11-21 ("No profiles for '<bundle ID>' were found"), now for the widget too.

## How it works

```
git tag v0.1.0 && git push --tags
        │
        ▼
GitHub Actions "iOS Ad Hoc" (.github/workflows/adhoc.yml, macos-26, environment: prod)
  ci/archive.sh     xcodebuild archive, automatic signing via the App Store Connect API key
  ci/export-ipa.sh  export method release-testing (= Ad Hoc) → build/export/LaCarte.ipa
  ci/verify-ipa.sh  for the app and the widget .appex: codesign OK, Ad Hoc profile for the right bundle ID,
                    same device UDIDs in both profiles, App Group signed + in both profiles
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
   It should print one `✓ <bundle> (<bundle ID>): Ad Hoc profile '…'` line per target (app, widget), then
   `✓ installs on:` followed by your iPhone's UDID. If the UDID is missing, the phone isn't registered:
   register it and re-run.
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
