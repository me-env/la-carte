#!/usr/bin/env bash
# Ad Hoc build, same steps as CI.
#   scripts/ios-adhoc.sh                                   signs with the account signed in to Xcode
#   AC_API_KEY_PATH=/path/AuthKey_<KEY_ID>.p8 scripts/ios-adhoc.sh   signs with the API key (like CI)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A key decoded from AC_API_KEY_BASE64 lands in build/; never leave it behind.
trap 'rm -f "$ROOT/build/asc-key.p8"' EXIT
"$ROOT/ci/archive.sh"
"$ROOT/ci/export-ipa.sh"
"$ROOT/ci/verify-ipa.sh"
