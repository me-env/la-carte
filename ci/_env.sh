# Shared CI settings (sourced).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A setting from ios/Config/Signing.xcconfig, overridden by Signing.local.xcconfig when present
# (same precedence as Xcode: the local file is included last).
signing_setting() {
  local f
  for f in "$ROOT/ios/Config/Signing.xcconfig" "$ROOT/ios/Config/Signing.local.xcconfig"; do
    if [ -f "$f" ]; then sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p" "$f"; fi
  done | tail -n 1
}
# Team: always from the xcconfig, so the project, the archive and ExportOptions agree.
TEAM_ID="$(signing_setting DEVELOPMENT_TEAM)"
# App Store Connect API key IDs (identifiers, not secrets). Defaults are this project's key;
# a fork sets ASC_KEY_ID / ASC_ISSUER_ID in the environment (CI: GitHub variables, see docs/release.md).
ASC_KEY_ID="${ASC_KEY_ID:-75U623RH52}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-1d327459-1aa2-4c1c-9ef3-561cea662e40}"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/LaCarte.xcarchive"
EXPORT="$BUILD/export"
IPA="$EXPORT/LaCarte.ipa"

# The .p8 key: AC_API_KEY_PATH (local) or AC_API_KEY_BASE64 (CI secret, decoded to a temp file).
asc_key_path() {
  if [ -n "${AC_API_KEY_PATH:-}" ]; then echo "$AC_API_KEY_PATH"; return; fi
  : "${AC_API_KEY_BASE64:?Set AC_API_KEY_PATH (local) or AC_API_KEY_BASE64 (CI)}"
  local path="$BUILD/asc-key.p8"
  mkdir -p "$BUILD"; umask 077
  echo "$AC_API_KEY_BASE64" | base64 --decode > "$path"
  echo "$path"
}

# Lets xcodebuild create/download the distribution certificate and an Ad Hoc profile
# (containing every device registered on the team).
# - With a key (CI): through the API key. The key needs the Admin role (cloud-managed
#   distribution certificates), otherwise export fails.
# - Without a key, locally: through the account signed in to Xcode and its local
#   Apple Distribution certificate. CI never falls back to this: a missing secret is an error.
# Call as `flags="$(auth_flags)"` so a failure stops the script under `set -e`.
auth_flags() {
  if [ -z "${AC_API_KEY_PATH:-}" ] && [ -z "${AC_API_KEY_BASE64:-}" ]; then
    if [ -n "${CI:-}" ]; then
      echo "error: AC_API_KEY_BASE64 is not set (prod environment secret)" >&2
      return 1
    fi
    echo "==> No API key: signing with the Xcode account" >&2
    echo -allowProvisioningUpdates
    return
  fi
  local key
  key="$(asc_key_path)" || return 1
  echo -allowProvisioningUpdates \
    -authenticationKeyPath "$key" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}
