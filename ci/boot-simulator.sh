#!/usr/bin/env bash
# CI only: boot the UI-test simulator before xcodebuild and initialise its appearance service.
# On the macos-26 runner, a simulator first booted by xcodebuild ignored XCUIDevice.shared.appearance (every
# System-theme "-dark" screenshot was light, qa/reports/ci-ios26-triage.md). Booting it fully and switching
# the appearance once with simctl makes later XCUIDevice changes take effect.
# Same device as scripts/_ios-env.sh picks ($SIMULATOR on $OS, "latest" = newest iOS runtime).
set -euo pipefail
source "$(dirname "$0")/../scripts/_ios-env.sh"

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

echo "Booting $SIMULATOR ($OS): $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true  # already booted is fine
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance dark
xcrun simctl ui "$UDID" appearance light
echo "appearance: $(xcrun simctl ui "$UDID" appearance)"
