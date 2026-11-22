#!/usr/bin/env bash
# CI only: build the app + UI tests once (build-for-testing) into $1 (an .xctestproducts dir), so test jobs run
# them without building (UI_TEST_PRODUCTS=$1 scripts/ios-ui-test.sh …). Same build as scripts/ios-ui-test.sh step 1.
set -euo pipefail
source "$(dirname "$0")/../scripts/_ios-env.sh"
PRODUCTS="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
rm -rf "$PRODUCTS"
# By UDID: on a cold runner, xcodebuild's own lookup of "name=…,OS=latest" timed out ("Unable to find a device").
UDID="$("$ROOT/ci/boot-simulator.sh" --udid)"
echo "build-for-testing: $(sysctl -n hw.ncpu) CPUs, $BUILD_JOBS_FLAGS, $SIMULATOR ($OS) = $UDID"
cd "$ROOT/ios"
set +e
NSUnbufferedIO=YES xcodebuild build-for-testing $BUILD_JOBS_FLAGS -project LaCarte.xcodeproj -scheme LaCarte \
  -destination "id=$UDID" -skipMacroValidation -testProductsPath "$PRODUCTS" -quiet 2>&1 \
  | grep --line-buffered -E "error:|\.swift:[0-9]+:[0-9]+: note:|BUILD (SUCCEEDED|FAILED)"
STATUS=${PIPESTATUS[0]}
set -e
[ "$STATUS" -eq 0 ] || exit "$STATUS"
du -sh "$PRODUCTS"
