#!/usr/bin/env bash
# CI only: boot the UI-test simulator before xcodebuild and initialise its appearance service.
# On the macos-26 runner, a simulator first booted by xcodebuild ignored XCUIDevice.shared.appearance (every
# System-theme "-dark" screenshot was light, qa/reports/ci-ios26-triage.md). Booting it fully and switching
# the appearance once with simctl makes later XCUIDevice changes take effect.
# Same device as scripts/_ios-env.sh picks ($SIMULATOR on $OS, "latest" = newest iOS runtime).
#
#   ci/boot-simulator.sh            boot now (foreground)
#   ci/boot-simulator.sh --start    boot in the background (log + exit code in $RUNNER_TEMP), e.g. while building
#   ci/boot-simulator.sh --wait     wait for that background boot (max 15 min), print its log, exit with its code
set -euo pipefail
STATE="${RUNNER_TEMP:-/tmp}/boot-simulator"
case "${1:-}" in
  --start)
    rm -f "$STATE.rc"
    ( set +e; "$0" > "$STATE.log" 2>&1; echo $? > "$STATE.rc.tmp"; mv "$STATE.rc.tmp" "$STATE.rc" ) &
    echo "Booting the simulator in the background (ci/boot-simulator.sh --wait)"; exit 0 ;;
  --wait)
    for _ in $(seq 1 900); do [ -f "$STATE.rc" ] && break; sleep 1; done
    cat "$STATE.log" 2>/dev/null || true
    [ -f "$STATE.rc" ] || { echo "::error::simulator boot did not finish in 15 min"; exit 1; }
    exit "$(cat "$STATE.rc")" ;;
esac
SECONDS=0
step() { echo "[$(printf '%3d' "$SECONDS") s] $*"; }
source "$(dirname "$0")/../scripts/_ios-env.sh"
step "start (CoreSimulator service)"

UDID=$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
name, os_ = sys.argv[1], sys.argv[2]
runtimes = json.load(sys.stdin)["devices"]
def version(rt):  # com.apple.CoreSimulator.SimRuntime.iOS-26-1 -> (26, 1)
    return tuple(int(p) for p in rt.rsplit("iOS-", 1)[1].split("-"))
ios = sorted((rt for rt in runtimes if "SimRuntime.iOS-" in rt), key=version, reverse=True)
if os_ != "latest":
    ios = [rt for rt in ios if version(rt)[:len(os_.split("."))] == tuple(int(p) for p in os_.split("."))]
for rt in ios:
    for d in runtimes[rt]:
        if d["name"] == name:
            print(d["udid"]); sys.exit()
sys.exit(f"no available simulator named {name!r} for iOS {os_}")
' "$SIMULATOR" "$OS")

step "booting $SIMULATOR ($OS): $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true  # already booted is fine
xcrun simctl bootstatus "$UDID" -b >/dev/null
step "booted"
# No "slide to type" intro over the first keyboard a test opens.
xcrun simctl spawn "$UDID" defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true || true
xcrun simctl ui "$UDID" appearance dark
xcrun simctl ui "$UDID" appearance light
step "appearance: $(xcrun simctl ui "$UDID" appearance)"
# A just-booted SpringBoard can refuse the first app launch ("failed preflight checks … Busy"): launch a system
# app once, so the test runner is not the first.
xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null && sleep 2 && xcrun simctl terminate "$UDID" com.apple.Preferences || true
step "ready"
