#!/usr/bin/env bash
# Unit tests: every feature/client in LaCarteKit (TCA TestStore + Swift Testing).
# Own DerivedData (LaCarteKit package) and own simulator ($UNIT_SIMULATOR), so it never waits behind an app
# build or a UI suite; only behind another unit-test run.
set -euo pipefail
source "$(dirname "$0")/_ios-env.sh"
cd "$ROOT/ios/LaCarteKit"
set +e
"$LOCK" "$KIT_BUILD_LOCK" "$LOCK" "$UNIT_SIM_LOCK" \
  xcodebuild test -scheme LaCarteKit -destination "$UNIT_DESTINATION" -skipMacroValidation 2>&1 \
  | grep -E "^(✔|✘|🔒)|error:|TEST (SUCCEEDED|FAILED)"
STATUS=${PIPESTATUS[0]}
set -e
exit "$STATUS"
