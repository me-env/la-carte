#!/usr/bin/env bash
# Build the app for the simulator. Waits for the app's DerivedData lock (not for the simulator).
set -euo pipefail
source "$(dirname "$0")/_ios-env.sh"
cd "$ROOT/ios"
"$LOCK" "$APP_BUILD_LOCK" $BUILD_SLOT xcodebuild build $BUILD_JOBS_FLAGS -project LaCarte.xcodeproj -scheme LaCarte \
  -destination "$DESTINATION" -skipMacroValidation -quiet
echo "✅ build succeeded"
