#!/usr/bin/env bash
# Unit tests: every feature/client in LaCarteKit (TCA TestStore + Swift Testing).
set -euo pipefail
source "$(dirname "$0")/_ios-env.sh"
cd "$ROOT/ios/LaCarteKit"
set +e
xcodebuild test -scheme LaCarteKit -destination "$DESTINATION" -skipMacroValidation 2>&1 \
  | grep -E "^(✔|✘)|error:|TEST (SUCCEEDED|FAILED)"
STATUS=${PIPESTATUS[0]}
set -e
exit "$STATUS"
