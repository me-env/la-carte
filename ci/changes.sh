#!/usr/bin/env bash
# CI only (job "What changed" in .github/workflows/ci.yml): which test sets this run needs. Prints `api=true|false`
# and `app=true|false` for $GITHUB_OUTPUT; the reasoning goes to stderr. See docs/ci-cd.md → Path filters.
#   api: API tests + image (and, on main, E2E + deploy)   app: iOS unit, UI smoke (PR) or UI shards + E2E (main)
# Compared with: a PR → its base. A push to main → the newest main commit with a green CI run, so the changes of
# every commit whose run was cancelled (or failed) since then are covered too. Nightly, manual run or no usable
# base → everything.
#   env: EVENT (github.event_name), PR_BASE (PR base sha), GH_TOKEN + GITHUB_REPOSITORY (push: reads run history)
set -euo pipefail
cd "$(dirname "$0")/.."

everything() { echo "Everything runs: $1" >&2; echo "api=true"; echo "app=true"; exit 0; }

case "${EVENT:?}" in
  pull_request) base=${PR_BASE:?} ;;
  push)
    base=$(gh run list -R "${GITHUB_REPOSITORY:?}" -w ci.yml -b main -s success -L 50 --json headSha,event \
      --jq '[.[] | select(.event != "pull_request")][0].headSha // empty') || everything "cannot read the run history"
    [[ -n "$base" ]] || everything "no green run on main in the last 50"
    ;;
  *) everything "$EVENT run" ;;
esac
git merge-base --is-ancestor "$base" HEAD 2>/dev/null || everything "base $base is not an ancestor of HEAD"

api=false app=false
changed=$(git diff --name-only "$base" HEAD)
while IFS= read -r f; do
  case "$f" in
    "") ;;
    api/* | docker-compose.yml | scripts/api-*) api=true ;;
    # Nothing on CI reads these. Anything not listed here runs everything (fail-safe).
    docs/* | qa/* | marketing/* | .claude/* | *.md | LICENSE | .gitignore \
      | .github/workflows/adhoc.yml | .github/workflows/ui-only.yml) ;;
    *) api=true app=true ;;
  esac
done <<<"$changed"

echo "Base $base, $(grep -c . <<<"$changed") files changed → api=$api app=$app" >&2
echo "api=$api"
echo "app=$app"
