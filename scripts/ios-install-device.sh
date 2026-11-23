#!/usr/bin/env bash
# Installs la-carte on a connected/paired iPhone (USB or same Wi-Fi).
#
#   scripts/ios-install-device.sh                 # latest .ipa from the "iOS Ad Hoc" GitHub workflow
#   scripts/ios-install-device.sh build/export/LaCarte.ipa
#
# DEVICE=<udid or name> picks the device (default: first paired physical iPhone).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IPA="${1:-}"

if [ -z "$IPA" ]; then
  DL="$ROOT/build/download"; rm -rf "$DL"
  RUN_ID="$(gh run list --workflow adhoc.yml --status success --limit 1 --json databaseId -q '.[0].databaseId')"
  [ -n "$RUN_ID" ] || { echo "No successful Ad Hoc run found"; exit 1; }
  gh run download "$RUN_ID" --name la-carte-ipa --dir "$DL"
  IPA="$DL/LaCarte.ipa"
fi

if [ -z "${DEVICE:-}" ]; then
  # JSON goes to its own file: devicectl also prints a human-readable table on stdout.
  JSON="$(mktemp)"; trap 'rm -f "$JSON"' EXIT
  xcrun devicectl list devices --timeout 30 --json-output "$JSON" >/dev/null
  # Xcode 27.2+ also lists simulators (hardwareProperties.reality == "simulated"): skip them, keep
  # paired iPhones, connected ones first. On failure, list what devicectl saw (names only, no IDs).
  DEVICE="$(python3 -I -c '
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
def hw(d): return d.get("hardwareProperties", {})
def conn(d): return d.get("connectionProperties", {})
phones = [d for d in devices if hw(d).get("deviceType") == "iPhone"
          and hw(d).get("reality") != "simulated"
          and conn(d).get("pairingState") == "paired"]
phones.sort(key=lambda d: conn(d).get("tunnelState") != "connected")
if phones:
    print(hw(phones[0]).get("udid") or phones[0]["identifier"])
else:
    for d in devices:
        if hw(d).get("reality") != "simulated":
            print(d.get("deviceProperties", {}).get("name"), hw(d).get("deviceType"), hw(d).get("reality"),
                  conn(d).get("pairingState"), conn(d).get("tunnelState"), sep=" | ", file=sys.stderr)' "$JSON")"
  [ -n "$DEVICE" ] || { echo "No paired iPhone found (xcrun devicectl list devices)"; exit 1; }
fi

# Bundle ID from the .ipa itself, so it follows Signing.xcconfig (and a fork's prefix).
BUNDLE_ID="$(unzip -p "$IPA" Payload/LaCarte.app/Info.plist | plutil -extract CFBundleIdentifier raw -)"

# devicectl waits forever on a device whose tunnel won't come up (seen 2026-11-23 over Wi-Fi: tunnel
# stuck "connecting" until the user's CoreDeviceService was restarted). So every call is bounded, and the
# device is probed first; if it doesn't answer, restart CoreDeviceService once (launchd relaunches it).
probe() { xcrun devicectl device info details --device "$DEVICE" --timeout 45 >/dev/null 2>&1; }
if ! probe; then
  echo "==> $DEVICE doesn't answer; restarting CoreDeviceService and retrying" >&2
  pkill -u "$(id -u)" -x CoreDeviceService || true
  sleep 3
  probe || { echo "Device $DEVICE doesn't answer: unlock the iPhone (or plug it in by cable) and re-run" >&2; exit 1; }
fi

echo "==> Installing $IPA on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" --timeout 600 "$IPA"
xcrun devicectl device process launch --device "$DEVICE" --timeout 60 "$BUNDLE_ID" || true
