#!/bin/bash
# Sanity checks on the exported .ipa: signature valid, Ad Hoc profile, which devices can install it.
set -euo pipefail
source "$(dirname "$0")/_env.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -q "$IPA" -d "$TMP"
APP="$(echo "$TMP"/Payload/*.app)"

codesign --verify --deep --strict "$APP"
echo "✓ codesign valid"

security cms -D -i "$APP/embedded.mobileprovision" > "$TMP/profile.plist"
DEVICES="$(plutil -extract ProvisionedDevices raw "$TMP/profile.plist" 2>/dev/null || echo 0)"
GET_TASK_ALLOW="$(plutil -extract Entitlements.get-task-allow raw "$TMP/profile.plist")"
[ "$GET_TASK_ALLOW" = "false" ] || { echo "✗ development profile, expected Ad Hoc"; exit 1; }
[ "$DEVICES" != "0" ] || { echo "✗ profile has no ProvisionedDevices"; exit 1; }
echo "✓ Ad Hoc profile '$(plutil -extract Name raw "$TMP/profile.plist")' for $DEVICES device(s):"
plutil -extract ProvisionedDevices json -o - "$TMP/profile.plist" | tr -d '[]"' | tr ',' '\n' | sed 's/^/    /'
echo "✓ version $(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist") ($(plutil -extract CFBundleVersion raw "$APP/Info.plist"))"
