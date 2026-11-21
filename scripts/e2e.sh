#!/usr/bin/env bash
# Full-stack E2E: fresh API + seeded deck → UI tests against it → screenshots in qa/screenshots/<run>.
# The UI run waits for the build/simulator locks itself (scripts/ios-ui-test.sh); the APIs are private to this run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="${1:-e2e-$(date +%Y%m%d-%H%M%S)}"
# Free ports picked by the OS, so several e2e runs (or a dev API) never clash. Override with E2E_PORT(S).
free_port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
PORT="${E2E_PORT:-$(free_port)}"
EMPTY_PORT="${E2E_EMPTY_PORT:-$(free_port)}"
TMP="$(mktemp -d)"
export LA_CARTE_API_URL="http://127.0.0.1:$PORT" LA_CARTE_API_TOKEN="e2e-token"

(cd "$ROOT/api" && LA_CARTE_DATABASE_URL="sqlite:///$TMP/e2e.db" LA_CARTE_PORT="$PORT" \
  exec uv run la-carte-api) >"$TMP/api.log" 2>&1 &
API_PID=$!
# Second, never-seeded API: the empty-deck state (`next_due: null`) against the real backend (spec 001 #6).
export TEST_RUNNER_LA_CARTE_EMPTY_API_URL="http://127.0.0.1:$EMPTY_PORT"
(cd "$ROOT/api" && LA_CARTE_DATABASE_URL="sqlite:///$TMP/e2e-empty.db" LA_CARTE_PORT="$EMPTY_PORT" \
  exec uv run la-carte-api) >"$TMP/api-empty.log" 2>&1 &
EMPTY_PID=$!
trap 'kill $API_PID $EMPTY_PID 2>/dev/null; rm -rf "$TMP"' EXIT
for url in "$LA_CARTE_API_URL" "$TEST_RUNNER_LA_CARTE_EMPTY_API_URL"; do
  for _ in $(seq 1 50); do curl -sf "$url/health" >/dev/null && break; sleep 0.2; done
done

# Seed order matters: spec 001 #10 studies `greeting` then `gratitude` (due order = creation order).
for pair in "greeting|hello" "gratitude|thank you"; do
  curl -sf -X POST "$LA_CARTE_API_URL/cards" -H "Authorization: Bearer $LA_CARTE_API_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"front\":\"${pair%%|*}\",\"back\":\"${pair##*|}\"}" >/dev/null
done

# Spec 003 #9 launches with no API env, types this API's URL + token in Settings and only reads (GET /stats,
# study), so it leaves the deck as seeded. XCTest runs classes alphabetically: Deck, Settings, then Study.
# Spec 004 forest live check only reads (study + deck), so it can run last.
# Spec 002 #13 adds "feline"/"cat" from study and deletes it again (net zero), so it can run before 001's flow.
# Spec 006 #12 POSTs "canine"/"dog", pulls deck + study, then DELETEs it (net zero): also before 001's flow.
"$ROOT/scripts/ios-ui-test.sh" "$RUN" \
  "-only-testing:LaCarteUITests/DeckUITests/testDeck_addFromStudyThenDelete_liveAPI" \
  "-only-testing:LaCarteUITests/RefreshUITests/testStudy_pullToRefresh_liveAPI" \
  "-only-testing:LaCarteUITests/SettingsUITests/testSettings_setupOnDevice_liveAPI" \
  "-only-testing:LaCarteUITests/StudyUITests/testStudy_revealRateToCaughtUp_liveAPI" \
  "-only-testing:LaCarteUITests/StudyUITests/testStudy_emptyDeck_liveAPI" \
  "-only-testing:LaCarteUITests/ThemeUITests/testTheme_forestDeck_liveAPI"
