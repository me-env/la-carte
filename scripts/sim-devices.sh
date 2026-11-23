#!/usr/bin/env bash
# Create the team's simulators if missing, each booted once so no test run pays a first boot. With LA_CARTE_SIM_DEVICES
# set (scripts/.local.env) their folders go to that volume, linked from ~/Library/Developer/CoreSimulator/Devices.
# Safe to rerun: it only creates what is missing. Run it while holding the simulator locks (docs/dev-velocity.md).
#
#   scripts/sim-devices.sh
set -euo pipefail
source "$(dirname "$0")/_ios-env.sh"
[ -z "${CI:-}" ] || { echo "not on CI (ci/boot-simulator.sh)" >&2; exit 64; }

runtime() {  # iOS runtime id for "latest" or a version like 26.5
  if [ "$1" = latest ]; then
    xcrun simctl list runtimes | sed -n 's/^iOS \([0-9.]*\) .* - \(com\.apple\.[^ ]*\).*/\1 \2/p' \
      | sort -t. -k1,1n -k2,2n | tail -1 | cut -d' ' -f2
  else
    xcrun simctl list runtimes | sed -n "s/^iOS ${1//./\\.} .* - \(com\.apple\.[^ ]*\).*/\1/p" | head -1
  fi
}
ensure() {  # <name> <device type> <runtime>: create (in the background) if missing
  local udid
  udid="$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
devices = json.load(sys.stdin)["devices"].get(sys.argv[1], [])
print(next((d["udid"] for d in devices if d["name"] == sys.argv[2] and d["isAvailable"]), ""))' "$3" "$1")"
  if [ -z "$udid" ]; then (echo "📱 $1 ($3): $(sim_create "$1" "$2" "$3")") & fi
}
LATEST="$(runtime latest)"
[ -n "$LATEST" ] || { echo "no iOS simulator runtime installed" >&2; exit 72; }
ensure "$SIMULATOR" "$SIMULATOR" "$LATEST"
ensure "$UNIT_SIMULATOR" "$UNIT_SIMULATOR" "$LATEST"
for n in $(seq 2 "$UI_POOL_SIZE"); do ensure "la-carte-ui-$n" "$SIMULATOR" "$LATEST"; done
for n in $(seq 2 "$UNIT_POOL_SIZE"); do ensure "la-carte-unit-$n" "$UNIT_SIMULATOR" "$LATEST"; done
# Older runtimes the team also tests on (CI parity): the two default models only; pool slots there are made on demand.
for os in ${SIM_DEVICES_EXTRA_OS-26.5}; do
  rt="$(runtime "$os")"
  if [ -z "$rt" ]; then echo "⚠️  no iOS $os runtime, skipped" >&2; continue; fi
  ensure "$SIMULATOR" "$SIMULATOR" "$rt"
  ensure "$UNIT_SIMULATOR" "$UNIT_SIMULATOR" "$rt"
done

wait
echo "✅ devices ready${LA_CARTE_SIM_DEVICES:+ in $LA_CARTE_SIM_DEVICES}"
