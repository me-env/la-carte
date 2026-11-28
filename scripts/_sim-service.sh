#!/usr/bin/env bash
# Run by _ios-env.sh (local, LA_CARTE_SIM_DEVICES set) after it mounts the device images. CoreSimulatorService reads
# the device folders when it starts: if it started before the images were mounted (after a reboot), simctl lists
# none of them and runs fail with "no simulator for the destination" (the pool would even create duplicates).
# Then restart the service, at most once per service process, and only while nobody uses it (it is shared with
# other projects): no simulator booted or booting, no xcodebuild, no Simulator app. Otherwise print what to do.
# Never fails its caller. `--missing` only prints the unlisted UDIDs.
# docs/dev-velocity.md, "Simulator service started before the images".
set -uo pipefail
source "$(dirname "$0")/_proc.sh"
DIR="${LOCK_DIR:-/tmp/la-carte-locks}"
MARK="$DIR/coresim-service.restarted"   # pid of the service we restarted into (/tmp is cleared at reboot)

missing() {  # UDIDs of mounted device images that simctl doesn't list; prints nothing if simctl doesn't answer
  local listed img u
  listed="$(bounded 60 xcrun simctl list devices)" || return 0
  for img in "$LA_CARTE_SIM_DEVICES"/*.sparsebundle; do
    u="$(basename "$img" .sparsebundle)"
    [ -f "$SIM_DEVICES_DIR/$u/device.plist" ] || continue   # not mounted, or not a device
    case "$listed" in *"($u)"*) ;; *) echo "$u" ;; esac
  done
}
service_pid() { { bounded 5 pgrep -U "$(id -u)" -f 'CoreSimulatorService.xpc/Contents/MacOS/' || true; } | head -1; }

if [ "${1:-}" = --missing ]; then missing; exit 0; fi   # used by _sim-pool.sh before it creates a device
if [ "${1:-}" != --locked ]; then
  [ -n "$(missing)" ] || exit 0          # the usual case: one simctl call (~0.2 s)
  mkdir -p "$DIR"
  exec lockf -s -t 120 "$DIR/coresim-service.lock" "$0" --locked   # one restart at a time; others recheck after
fi

M="$(missing)"
[ -n "$M" ] || exit 0                    # another script restarted it meanwhile
N=$(echo $M | wc -w | tr -d ' ')
PID="$(service_pid)"
if [ -n "$PID" ] && [ "$(cat "$MARK" 2>/dev/null)" = "$PID" ]; then
  echo "⚠️  simctl still doesn't list $N mounted simulator image(s) after a restart ($(echo $M | tr ' ' ',')): not retrying. docs/dev-velocity.md" >&2
  exit 0
fi
BUSY=""
if bounded 30 xcrun simctl list devices | grep -qE '\((Booted|Booting|Shutting Down)\)'; then BUSY="a simulator is booted"
elif bounded 5 pgrep -x xcodebuild >/dev/null; then BUSY="an xcodebuild is running"
elif bounded 5 pgrep -x Simulator >/dev/null; then BUSY="the Simulator app is open"
fi
if [ -n "$BUSY" ]; then
  echo "⚠️  simctl doesn't list $N mounted simulator image(s): CoreSimulatorService started before they were mounted." \
    "Not restarting it, $BUSY (maybe another project). Runs may fail with 'no simulator for the destination'." \
    "Once nothing uses simulators, rerun. docs/dev-velocity.md" >&2
  exit 0
fi
echo "🔄 simctl doesn't list $N mounted simulator image(s) (service started before they were mounted): restarting CoreSimulatorService, nothing uses it" >&2
[ -z "$PID" ] || kill "$PID" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do       # up to 5 s for it to exit; the next simctl call starts a new one
  [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || break
  sleep 0.5
done
M="$(missing)"
service_pid >"$MARK"
if [ -n "$M" ]; then echo "⚠️  still missing after the restart: $(echo $M | tr ' ' ',')" >&2
else echo "✅ CoreSimulatorService restarted: all mounted simulators listed" >&2
fi
exit 0
