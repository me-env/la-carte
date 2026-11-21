#!/bin/bash
# Exports an Ad Hoc .ipa (installable on devices registered on the team).
set -euo pipefail
source "$(dirname "$0")/_env.sh"
flags="$(auth_flags)"
rm -rf "$EXPORT"

# shellcheck disable=SC2086  # $flags is a word list
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/ios/Config/ExportOptions-AdHoc.plist" \
  $flags
echo "==> Exported $IPA"
