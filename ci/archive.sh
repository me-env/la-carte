#!/bin/bash
# Archives the app (Release). Version comes from VERSION (e.g. tag v1.2.0 → 1.2.0),
# build number from BUILD_NUMBER (CI run number). Locally: latest v* tag (else 0.1.0) and a timestamp.
set -euo pipefail
source "$(dirname "$0")/_env.sh"
LATEST_TAG="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
VERSION="${VERSION:-${LATEST_TAG:-v0.1.0}}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
flags="$(auth_flags)"
rm -rf "$ARCHIVE"

# shellcheck disable=SC2086  # $flags is a word list
xcodebuild archive \
  -project "$ROOT/ios/LaCarte.xcodeproj" \
  -scheme LaCarte \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -skipMacroValidation \
  $flags \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet
echo "==> Archived $VERSION ($BUILD_NUMBER) → $ARCHIVE"
