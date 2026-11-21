#!/bin/bash
# Exports an Ad Hoc .ipa (installable on devices registered on the team).
set -euo pipefail
source "$(dirname "$0")/_env.sh"
rm -rf "$EXPORT"

# shellcheck disable=SC2046
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/ios/Config/ExportOptions-AdHoc.plist" \
  $(auth_flags)
echo "==> Exported $IPA"
