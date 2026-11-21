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
  xcrun devicectl list devices --json-output "$JSON" >/dev/null
  DEVICE="$(python3 -I -c '
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
phones = [d for d in devices if d["hardwareProperties"].get("deviceType") == "iPhone"
          and d["hardwareProperties"].get("reality") == "physical"]
print(phones[0]["hardwareProperties"]["udid"] if phones else "")' "$JSON")"
  [ -n "$DEVICE" ] || { echo "No paired iPhone found (xcrun devicectl list devices)"; exit 1; }
fi

echo "==> Installing $IPA on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$IPA"
xcrun devicectl device process launch --device "$DEVICE" fr.lacarte.app || true
