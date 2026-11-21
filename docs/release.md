# Release: getting la-carte onto the iPhone

Owner: `release-engineer` agent. Pattern adapted from l'alfred (`lalfred-app/ci/`), for iOS Ad Hoc.

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

There's no .p12 or provisioning profile to manage. With `-allowProvisioningUpdates` and the API key,
Xcode creates or downloads the Apple Distribution certificate and an Ad Hoc profile containing
**every device registered on team 5X9ZWT7KT3**.

`CI` (`.github/workflows/ci.yml`) runs on every PR and push to main: API tests, the API Docker image build (`docs/deploy.md`), iOS unit tests, UI tests
(mock deck), and live E2E. Screenshots are uploaded as the `screenshots` artifact.

## One-time setup

1. **Register the iPhone** on team 5X9ZWT7KT3 (developer.apple.com → Devices), UDID
   `00008150-001C18962ED0C01C`. Ad Hoc builds only install on registered devices.
   Opening the project in Xcode with the phone connected and building to it also registers it.
2. **GitHub repo** with an environment named `prod` holding the secret `AC_API_KEY_BASE64`. It's the same
   key as l'alfred: `base64 -i AuthKey_75U623RH52.p8 | gh secret set AC_API_KEY_BASE64 --env prod`.
   Key ID and issuer are in `ci/_env.sh` (they're identifiers, not secrets).
3. The API key needs the **Admin** role to create distribution certificates through the API. If the
   archive step fails with a certificate or permission error, create an "Apple Distribution"
   certificate once in Xcode (Settings → Accounts → Manage Certificates), then re-run.
4. Developer Mode must be on on the iPhone (Settings → Privacy & Security), for both Ad Hoc and dev installs.

## First run (needs you)

Run these once on the Mac, with the iPhone unlocked and paired (USB or same Wi-Fi). They're the only steps
that touch your Apple account, so no agent runs them for you.

1. Make sure the iPhone `00008150-001C18962ED0C01C` is registered on team 5X9ZWT7KT3
   (developer.apple.com → Devices) and Developer Mode is on. See one-time setup, steps 1 and 4.
2. Build the signed Ad Hoc .ipa locally. This creates the distribution certificate and Ad Hoc profile through the API key:
   ```bash
   AC_API_KEY_PATH=/absolute/path/to/AuthKey_75U623RH52.p8 scripts/ios-adhoc.sh
   ```
   It should end with `✓ Ad Hoc profile '…' for N device(s):`, followed by the UDID above. If the UDID
   is missing, the phone isn't registered: register it and re-run.
3. Install and launch it:
   ```bash
   scripts/ios-install-device.sh build/export/LaCarte.ipa
   ```
   The first launch of an Ad Hoc build may ask you to trust the developer: on the iPhone, Settings →
   General → VPN & Device Management.
4. Later, once the GitHub repo exists: one-time setup, step 2 (the `prod` secret), then tag as below.

Checked without the account (2026-11-21, Xcode 27.0): an unsigned Release archive for `generic/platform=iOS`
builds (arm64, `fr.lacarte.app`, `MinimumOSVersion` 26.0, version overrides applied). You can reproduce it with
`xcodebuild archive -project ios/LaCarte.xcodeproj -scheme LaCarte -configuration Release -destination generic/platform=iOS -archivePath build/LaCarte.xcarchive -skipMacroValidation CODE_SIGNING_ALLOWED=NO`.
Signing, export and install have **not** been run yet. They're the steps above.

## Everyday

| I want to… | Run |
|---|---|
| ship a build to my phone | `git tag v0.1.0 && git push --tags`, then `scripts/ios-install-device.sh` |
| rebuild without a tag | Actions → iOS Ad Hoc → Run workflow |
| build the .ipa locally | `AC_API_KEY_PATH=…/AuthKey_75U623RH52.p8 scripts/ios-adhoc.sh` |
| install a local .ipa | `scripts/ios-install-device.sh build/export/LaCarte.ipa` |
| debug on device | open `ios/LaCarte.xcodeproj`, choose the iPhone, Run |

Versioning: `MARKETING_VERSION` comes from the tag (`v1.2.0` → `1.2.0`); the build number is the
workflow run number.

The deployment target is **iOS 26.0**, so the app builds with Xcode 26.x (what the `macos-26` runner has,
up to 26.6) as well as Xcode 27 (the Mac). Both workflows use `setup-xcode` with `latest-stable`, the newest
non-beta Xcode on the image, and pick Xcode 27 automatically once the image ships it. Keep the project
format at `objectVersion = 77` (Xcode 16 format) so Xcode 26 can open it. If Xcode 27 on the Mac bumps it
to 90 when saving the project, set it back.

## The API the phone talks to
The simulator reaches `127.0.0.1:8000` on the Mac, but a phone can't. Deploy the API with HTTPS
(`docs/deploy.md`, Dokploy) and enter its URL and token in the app's Settings screen (spec 003, backlog #5).
