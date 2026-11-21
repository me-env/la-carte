#!/bin/bash
# Exports an Ad Hoc .ipa (installable on devices registered on the team).
set -euo pipefail
source "$(dirname "$0")/_env.sh"
flags="$(auth_flags)"
rm -rf "$EXPORT"
# ExportOptions gets the team from Signing.xcconfig (see _env.sh), not a hard-coded value.
OPTIONS="$BUILD/ExportOptions-AdHoc.plist"
cp "$ROOT/ios/Config/ExportOptions-AdHoc.plist" "$OPTIONS"
plutil -insert teamID -string "$TEAM_ID" "$OPTIONS"

# shellcheck disable=SC2086  # $flags is a word list
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$OPTIONS" \
  $flags
echo "==> Exported $IPA"
