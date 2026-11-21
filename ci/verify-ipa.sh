#!/bin/bash
# Sanity checks on the exported .ipa, for the app and every embedded extension (spec 007: the widget):
# signature valid, Ad Hoc profile for the right bundle ID, which devices can install it, and the App Group.
set -euo pipefail
source "$(dirname "$0")/_env.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -q "$IPA" -d "$TMP"
APP="$(echo "$TMP"/Payload/*.app)"
PREFIX="$(signing_setting LA_CARTE_BUNDLE_ID_PREFIX)"
GROUP="group.$PREFIX.app"
shopt -s nullglob
APPEXES=("$APP"/PlugIns/*.appex)

# Prints the value at a key path in a plist (keys may contain dots, so not plutil -extract) as JSON.
plist_get() {
  python3 -I -c '
import json, plistlib, sys
v = plistlib.load(open(sys.argv[1], "rb"))
for k in sys.argv[2:]:
    v = v.get(k) if isinstance(v, dict) else None
print(json.dumps(v, sort_keys=True))' "$@"
}

codesign --verify --deep --strict "$APP"
echo "✓ codesign valid (app and ${#APPEXES[@]} extension(s))"

# check_bundle <bundle> <expected bundle ID>: prints the bundle's device list to $TMP/<name>.devices.
check_bundle() {
  local bundle="$1" expected_id="$2" name; name="$(basename "$bundle")"
  local id; id="$(plutil -extract CFBundleIdentifier raw "$bundle/Info.plist")"
  [ "$id" = "$expected_id" ] || { echo "✗ $name: bundle ID $id, expected $expected_id"; exit 1; }
  codesign --verify --strict "$bundle"

  local profile="$TMP/$name.profile.plist"
  security cms -D -i "$bundle/embedded.mobileprovision" > "$profile"
  [ "$(plist_get "$profile" Entitlements get-task-allow)" = "false" ] \
    || { echo "✗ $name: development profile, expected Ad Hoc"; exit 1; }
  [ "$(plist_get "$profile" Entitlements application-identifier)" = "\"$TEAM_ID.$id\"" ] \
    || { echo "✗ $name: profile is not for $TEAM_ID.$id"; exit 1; }
  local devices; devices="$(plist_get "$profile" ProvisionedDevices)"
  [ "$devices" != "null" ] && [ "$devices" != "[]" ] || { echo "✗ $name: profile has no ProvisionedDevices"; exit 1; }
  echo "$devices" | tr -d '[]" ' | tr ',' '\n' | sort > "$TMP/$name.devices"

  # With an extension, both targets share the App Group: the signature must carry it, and the profile allow it.
  if [ ${#APPEXES[@]} -gt 0 ]; then
    codesign -d --entitlements - --xml "$bundle" > "$TMP/$name.entitlements.plist" 2>/dev/null
    [ "$(plist_get "$TMP/$name.entitlements.plist" com.apple.security.application-groups)" = "[\"$GROUP\"]" ] \
      || { echo "✗ $name: signed App Groups $(plist_get "$TMP/$name.entitlements.plist" com.apple.security.application-groups), expected [\"$GROUP\"]"; exit 1; }
    plist_get "$profile" Entitlements com.apple.security.application-groups | grep -q "\"$GROUP\"" \
      || { echo "✗ $name: profile doesn't include App Group $GROUP"; exit 1; }
  fi
  echo "✓ $name ($id): Ad Hoc profile '$(plist_get "$profile" Name | tr -d '"')', $(wc -l < "$TMP/$name.devices" | tr -d ' ') device(s)"
}

check_bundle "$APP" "$PREFIX.app"
for appex in ${APPEXES[@]+"${APPEXES[@]}"}; do  # bash 3.2: empty array + set -u
  check_bundle "$appex" "$PREFIX.app.widget"
  # The phone needs its UDID in every embedded profile, or the whole install fails.
  diff -q "$TMP/$(basename "$APP").devices" "$TMP/$(basename "$appex").devices" >/dev/null \
    || { echo "✗ $(basename "$appex"): device list differs from the app's (re-run the build so Xcode regenerates both profiles)"; exit 1; }
done
[ ${#APPEXES[@]} -eq 0 ] || echo "✓ App Group $GROUP signed and provisioned on every target"

echo "✓ installs on:"
sed 's/^/    /' "$TMP/$(basename "$APP").devices"
echo "✓ version $(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist") ($(plutil -extract CFBundleVersion raw "$APP/Info.plist"))"
