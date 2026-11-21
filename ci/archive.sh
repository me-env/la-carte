#!/bin/bash
# Archives the app (Release). Version comes from VERSION (e.g. tag v1.2.0 → 1.2.0),
# build number from BUILD_NUMBER (CI run number); both default to local-friendly values.
set -euo pipefail
source "$(dirname "$0")/_env.sh"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
rm -rf "$ARCHIVE"

# shellcheck disable=SC2046
xcodebuild archive \
  -project "$ROOT/ios/LaCarte.xcodeproj" \
  -scheme LaCarte \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -skipMacroValidation \
  $(auth_flags) \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet
echo "==> Archived $VERSION ($BUILD_NUMBER) → $ARCHIVE"
