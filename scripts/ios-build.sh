#!/usr/bin/env bash
# Build the app for the simulator.
set -euo pipefail
source "$(dirname "$0")/_ios-env.sh"
cd "$ROOT/ios"
xcodebuild build -project LaCarte.xcodeproj -scheme LaCarte -destination "$DESTINATION" \
  -skipMacroValidation -quiet
echo "✅ build succeeded"
