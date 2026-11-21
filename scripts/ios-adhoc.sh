#!/usr/bin/env bash
# Local Ad Hoc build, same steps as CI.  AC_API_KEY_PATH=/path/AuthKey_75U623RH52.p8 scripts/ios-adhoc.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A key decoded from AC_API_KEY_BASE64 lands in build/; never leave it behind.
trap 'rm -f "$ROOT/build/asc-key.p8"' EXIT
"$ROOT/ci/archive.sh"
"$ROOT/ci/export-ipa.sh"
"$ROOT/ci/verify-ipa.sh"
