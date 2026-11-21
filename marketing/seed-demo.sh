#!/usr/bin/env bash
# Seed the demo deck (marketing/demo-deck.json) into a LOCAL, throwaway la-carte API over REST.
#
#   TMP=$(mktemp -d)
#   LA_CARTE_DATABASE_URL="sqlite:///$TMP/demo.db" LA_CARTE_API_TOKEN=demo-token scripts/api-dev.sh &
#   marketing/seed-demo.sh
#
# Never point this at a real deck: it refuses any host but 127.0.0.1/localhost and any non-empty deck.
# Env: LA_CARTE_API_URL (default http://127.0.0.1:8000), LA_CARTE_API_TOKEN (default demo-token, fake).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
URL="${LA_CARTE_API_URL:-http://127.0.0.1:8000}"
TOKEN="${LA_CARTE_API_TOKEN:-demo-token}"
DECK="$DIR/demo-deck.json"

case "$URL" in
  http://127.0.0.1:*|http://localhost:*|http://127.0.0.1|http://localhost) ;;
  *) echo "Refusing to seed $URL: local throwaway API only (http://127.0.0.1:<port>)." >&2; exit 1 ;;
esac

api() { curl -sf -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }

total="$(api "$URL/stats" | jq .total)" || { echo "No API at $URL (start scripts/api-dev.sh first)." >&2; exit 1; }
if [ "$total" != "0" ]; then
  echo "Deck at $URL already has $total cards. Use a fresh temp DB." >&2; exit 1
fi

# Same order as the file: due cards are studied in creation order.
jq -c '.cards[]' "$DECK" | while read -r card; do
  id="$(api -X POST "$URL/cards" -d "$(jq -c '{front, back}' <<<"$card")" | jq -r .id)"
  rating="$(jq -r '.review // empty' <<<"$card")"
  if [ -n "$rating" ]; then
    api -X POST "$URL/cards/$id/review" -d "{\"rating\":\"$rating\"}" >/dev/null
  fi
done

api "$URL/stats" | jq -c '{total, due, new, reviewed_today}'
