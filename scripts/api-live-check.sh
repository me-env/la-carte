#!/usr/bin/env bash
# Is the deployed API running this working tree's code? Compares /health "build" with the local source hash.
#   scripts/api-live-check.sh [url]     (default: $LA_CARTE_LIVE_URL)   exit 0 = up to date, 1 = behind
set -euo pipefail
url="${1:-${LA_CARTE_LIVE_URL:-}}"
[[ -n "$url" ]] || { echo "usage: $0 <url>  (or set LA_CARTE_LIVE_URL)" >&2; exit 2; }
cd "$(dirname "$0")/../api"
local_build=$(uv run --quiet python -c 'from la_carte_api.build import source_hash; print(source_hash())')
live_build=$(curl -fsS --max-time 10 "${url%/}/health" \
  | uv run --quiet python -c 'import json, sys; print(json.load(sys.stdin).get("build", "unknown"))')
if [[ "$live_build" == "$local_build" ]]; then
  echo "live build $live_build / local build $local_build → up to date"
else
  echo "live build $live_build / local build $local_build → behind"
  exit 1
fi
