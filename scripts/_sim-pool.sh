#!/usr/bin/env bash
# Run a command on the first free unit-test simulator of a small pool, holding that device's lock, so unit
# tests from several checkouts/worktrees run side by side instead of queuing for one device.
#
#   scripts/_sim-pool.sh <command> [args...]     (the command reads $POOL_DESTINATION, an xcodebuild -destination)
#
# Slot 1 is $UNIT_SIMULATOR with lock $UNIT_SIM_LOCK: the same device and lock as older scripts, so worktrees
# that still run them share it correctly. Slots 2..$UNIT_POOL_SIZE are simulators named "la-carte-unit-<n>",
# created on first use ($UNIT_SIMULATOR's device type, $OS runtime), each with its own lock.
# Tries each slot without waiting; if all are busy, retries every 2 s (fair enough for a handful of agents) until
# one frees up or LOCK_TIMEOUT passes (exit 75). Locks are the same kernel locks as scripts/_lock.sh (lockf,
# dropped on exit or crash) in LOCK_DIR, with the same holder notes.
set -euo pipefail
source "$(dirname "$0")/_ios-env.sh"
DIR="${LOCK_DIR:-/tmp/la-carte-locks}"
mkdir -p "$DIR"
slot_lock() { if [ "$1" -eq 1 ]; then echo "$UNIT_SIM_LOCK"; else echo "sim-la-carte-unit-$1-$LOCK_OS"; fi; }

# Internal: we now hold slot $2's lock. Find or create its device, then run the command.
if [ "${1:-}" = --on-slot ]; then
  SLOT="$2"; shift 2
  if [ "$SLOT" -eq 1 ]; then
    export POOL_DESTINATION="$UNIT_DESTINATION"
  else
    NAME="la-carte-unit-$SLOT"
    if [ "$OS" = latest ]; then
      RUNTIME="$(xcrun simctl list runtimes | sed -n 's/^iOS \([0-9.]*\) .* - \(com\.apple\.[^ ]*\).*/\1 \2/p' \
        | sort -t. -k1,1n -k2,2n | tail -1 | cut -d' ' -f2)"
    else
      RUNTIME="$(xcrun simctl list runtimes | sed -n "s/^iOS ${OS//./\\.} .* - \(com\.apple\.[^ ]*\).*/\1/p" | head -1)"
    fi
    [ -n "$RUNTIME" ] || { echo "no iOS $OS simulator runtime installed" >&2; exit 72; }
    UDID="$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
devices = json.load(sys.stdin)["devices"].get(sys.argv[1], [])
print(next((d["udid"] for d in devices if d["name"] == sys.argv[2] and d["isAvailable"]), ""))' "$RUNTIME" "$NAME")"
    if [ -z "$UDID" ]; then
      echo "📱 creating simulator $NAME ($UNIT_SIMULATOR, $RUNTIME), about 1.5 GB once used" >&2
      UDID="$(xcrun simctl create "$NAME" "$UNIT_SIMULATOR" "$RUNTIME")"
    fi
    export POOL_DESTINATION="platform=iOS Simulator,id=$UDID"
  fi
  exec "$@"
fi

[ $# -ge 1 ] || { echo "usage: $0 <command> [args...]" >&2; exit 64; }
SIZE="${UNIT_POOL_SIZE:-3}"
for k in $(seq 1 "$SIZE"); do  # an outer caller already holds a slot: use it
  case " ${LACARTE_HELD_LOCKS:-} " in *" $(slot_lock "$k") "*) exec "$0" --on-slot "$k" "$@" ;; esac
done
export LACARTE_LOCK_LABEL="${LACARTE_LOCK_LABEL:-$(ps -o command= -p $PPID | cut -c1-120)}"
TIMEOUT="${LOCK_TIMEOUT:-3600}"
MARK="$(mktemp)"; trap 'rm -f "$MARK"' EXIT   # removed by the locked command once it starts
holders() { for k in $(seq 1 "$SIZE"); do printf '\n  %s: %s' "$(slot_lock "$k")" \
  "$(cat "$DIR/$(slot_lock "$k").lock.holder" 2>/dev/null || echo '?')"; done; }
WAITING=""
while :; do
  for k in $(seq 1 "$SIZE"); do
    NAME="$(slot_lock "$k")"; FILE="$DIR/$NAME.lock"
    HOLDER="${LACARTE_AGENT:-unnamed agent} · $LACARTE_LOCK_LABEL · pid $$ · since $(date +%H:%M:%S)"
    : >"$MARK"
    set +e
    # shellcheck disable=SC2016  # $1..$3 expand inside the child shell
    LACARTE_HELD_LOCKS="${LACARTE_HELD_LOCKS:-} $NAME" lockf -s -k -t 0 "$FILE" \
      /bin/sh -c 'rm -f "$1"; printf "%s\n" "$2" >"$3.holder"; shift 3; exec "$@"' \
      sh "$MARK" "$HOLDER" "$FILE" "$0" --on-slot "$k" "$@"
    STATUS=$?
    set -e
    [ -e "$MARK" ] || exit "$STATUS"   # the command ran on this slot: its exit code is ours
  done
  if [ -z "$WAITING" ]; then
    WAITING=$SECONDS
    echo "🔒 all $SIZE unit-test simulators busy, waiting (up to ${TIMEOUT}s), held by:$(holders)" >&2
  elif [ $((SECONDS - WAITING)) -ge "$TIMEOUT" ]; then
    echo "🔒 gave up after ${TIMEOUT}s waiting for a unit-test simulator, held by:$(holders)" >&2
    exit 75
  fi
  sleep 2
done
