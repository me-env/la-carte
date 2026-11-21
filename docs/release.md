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

There's no .p12 or provisioning profile to manage. With `-allowProvisioningUpdates`, Xcode creates or
downloads the Apple Distribution certificate and an Ad Hoc profile ("iOS Team Ad Hoc Provisioning
Profile: fr.lacarte.app") containing **every device registered on team 5X9ZWT7KT3**. Both are valid
about **one year**; after that, re-run a build and Xcode renews them.

Two ways to sign, chosen by `auth_flags` in `ci/_env.sh`:

| Where | Auth | Needs |
|---|---|---|
| CI | API key (`AC_API_KEY_BASE64`) | key with the **Admin** role, or "Access to Cloud Managed Distribution Certificate" |
| Mac, no key set | the account signed in to Xcode | a local "Apple Distribution: … (5X9ZWT7KT3)" certificate in the keychain |

CI never falls back to the Xcode account: if `CI` is set and the secret is missing, the job fails.
With a key, xcodebuild uses the key's role and ignores the local certificate.

`CI` (`.github/workflows/ci.yml`) runs on every PR and push to main: API tests, the API Docker image build (`docs/deploy.md`), iOS unit tests, UI tests
(mock deck), and live E2E. Screenshots are uploaded as the `screenshots` artifact.

## One-time setup

1. **Register the iPhone** on team 5X9ZWT7KT3 (developer.apple.com → Devices), UDID
   `00008150-001C18962ED0C01C`. Ad Hoc builds only install on registered devices.
   Opening the project in Xcode with the phone connected and building to it also registers it.
2. **GitHub repo** with an environment named `prod` holding the secret `AC_API_KEY_BASE64`. It's the same
   key as l'alfred: `base64 -i AuthKey_75U623RH52.p8 | gh secret set AC_API_KEY_BASE64 --env prod`.
   Key ID and issuer are in `ci/_env.sh` (they're identifiers, not secrets).
3. For CI, the API key needs the **Admin** role (or "Access to Cloud Managed Distribution Certificate").
   Found on 2026-11-21: with a key without it, archive succeeds but export fails with
   "Cloud signing permission error: You haven't been given access to cloud-managed distribution
   certificates" and "No profiles for 'fr.lacarte.app' were found". A local Apple Distribution
   certificate doesn't help there. Change the key's role in App Store Connect → Users and Access →
   Integrations, or make a new key with that access.
4. Developer Mode must be on on the iPhone (Settings → Privacy & Security), for both Ad Hoc and dev installs.

## First run (needs you)

Run these once on the Mac, with the iPhone unlocked and paired (USB or same Wi-Fi). They touch your
Apple account, so no agent runs them for you. This is what worked on 2026-11-21.

1. In Xcode → Settings → Accounts → team 5X9ZWT7KT3 → Manage Certificates, create an
   **Apple Distribution** certificate (once, valid about a year).
2. Plug in the iPhone `00008150-001C18962ED0C01C` (Developer Mode on, see one-time setup step 4).
   It must be registered on the team (one-time setup step 1).
3. Build the signed Ad Hoc .ipa with the Xcode account (no API key):
   ```bash
   scripts/ios-adhoc.sh
   ```
   It should end with `✓ Ad Hoc profile '…' for N device(s):`, followed by the UDID above. If the UDID
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
| reproduce CI signing locally | `AC_API_KEY_PATH=…/AuthKey_75U623RH52.p8 scripts/ios-adhoc.sh` |
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
(`docs/deploy.md`, Dokploy) and enter its URL and token in the app's Settings screen (spec 003, backlog #5).
