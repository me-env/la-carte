#!/usr/bin/env bash
# Unit tests: every feature/client in LaCarteKit (TCA TestStore + Swift Testing).
set -euo pipefail
source "$(dirname "$0")/_ios-env.sh"
cd "$ROOT/ios/LaCarteKit"
xcodebuild test -scheme LaCarteKit -destination "$DESTINATION" -skipMacroValidation 2>&1 \
  | grep -E "^(✔|✘)|error:|TEST (SUCCEEDED|FAILED)" || true
test "${PIPESTATUS[0]}" -eq 0
