#!/usr/bin/env bash
# CI only (job "Deploy API" in .github/workflows/ci.yml, after the API jobs passed on this commit):
# trigger the Dokploy compose deploy, wait for it, then check the public /health build hash. See docs/ci-cd.md.
#   env: DOKPLOY_URL (e.g. https://app.dokploy.com), DOKPLOY_API_KEY, DOKPLOY_COMPOSE_ID, LA_CARTE_LIVE_URL (secret, never printed),
#        GITHUB_SHA, BEFORE_SHA (previous main head; empty or unknown = deploy)
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DOKPLOY_URL:?}" "${DOKPLOY_API_KEY:?}" "${DOKPLOY_COMPOSE_ID:?}" "${LA_CARTE_LIVE_URL:?}" "${GITHUB_SHA:?}"
dokploy() { curl -fsS --max-time 30 -H "x-api-key: $DOKPLOY_API_KEY" "$@"; }

# 1. Dokploy builds the head of main, not a given commit. Deploy only if the head's image inputs (api/,
#    docker-compose.yml) are the ones tested here; otherwise a newer run tests and deploys them.
head=$(git ls-remote origin refs/heads/main | cut -f1)
if [[ "$head" != "$GITHUB_SHA" ]]; then
  if ! git fetch --quiet origin "$head" || ! git diff --quiet "$GITHUB_SHA" "$head" -- api docker-compose.yml; then
    echo "main moved on to $head with other API changes: its own run deploys them. Skipping."
    exit 0
  fi
  echo "main moved on to $head, same api/ + docker-compose.yml as this tested commit: deploying."
fi

# 2. Anything to deploy? The live source hash differs (also catches commits whose runs were cancelled),
#    or the image inputs (api/, docker-compose.yml) changed since the previous push.
if scripts/api-live-check.sh "$LA_CARTE_LIVE_URL"; then
  if [[ -n "${BEFORE_SHA:-}" && "$BEFORE_SHA" != 0000000000000000000000000000000000000000 ]] \
    && git fetch --quiet --depth=1 origin "$BEFORE_SHA" \
    && git diff --quiet "$BEFORE_SHA" "$GITHUB_SHA" -- api docker-compose.yml; then
    echo "API already live and api/ + docker-compose.yml unchanged: nothing to deploy."
    exit 0
  fi
fi

# 3. Deploy (queued; the call returns at once). We track the deployment that appears after this call
#    (Dokploy may rewrite its title, so we go by id, not title).
list_url="${DOKPLOY_URL%/}/api/deployment.allByCompose?composeId=$DOKPLOY_COMPOSE_ID"
old_ids=$(dokploy "$list_url" | jq -c '[.[].deploymentId]')
title="CI ${GITHUB_SHA:0:7}"
dokploy -X POST "${DOKPLOY_URL%/}/api/compose.deploy" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg c "$DOKPLOY_COMPOSE_ID" --arg t "$title" '{composeId: $c, title: $t}')"
echo
echo "Deploy queued: $title"

# 4. Wait for Dokploy to finish it (status running → done | error | cancelled), up to 15 min.
status=pending
for _ in $(seq 1 90); do
  sleep 10
  # A failed request is retried; a response we can't read fails at once (the API changed).
  deployments=$(dokploy "$list_url") \
    || { echo "dokploy: request failed, retrying"; continue; }
  status=$(jq -er --argjson old "$old_ids" '[.[] | select(.deploymentId as $i | $old | index($i) | not)] | sort_by(.createdAt) | last | .status // "pending"' \
    <<<"$deployments") || { echo "::error::Unexpected deployment.allByCompose response from Dokploy"; exit 1; }
  echo "dokploy: $status"
  case "$status" in
    done) break ;;
    error | cancelled) echo "::error::Dokploy deployment '$title' ended with status $status (see its logs in Dokploy)"; exit 1 ;;
  esac
done
[[ "$status" == "done" ]] || { echo "::error::Dokploy deployment '$title' not done after 15 min (last: $status)"; exit 1; }

# 5. The public API serves this commit's code (the container may take a few seconds to answer).
for _ in $(seq 1 12); do
  scripts/api-live-check.sh "$LA_CARTE_LIVE_URL" && exit 0
  sleep 5
done
echo "::error::Deployed, but the live /health does not report this commit's build"
exit 1
