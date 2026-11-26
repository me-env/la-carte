# QA: 029 Activity log

Verdict: PASS
Date: 2026-11-26 · Simulator: iPhone 17 Pro / iOS 27.0
Branch: `worktree-agent-a92a32e62be61b938` (iOS 8c049e1) + merged API branch `worktree-agent-acbdf640e1bc2e82a` (ede9e76)
Runs: `qa/screenshots/029-mock/` (AC 30/31), `qa/screenshots/029-mock-delivery/` (buffer + retry), `qa/screenshots/029-e2e/` (AC 32)
Commands:
- `scripts/api-test.sh` ✅ ruff clean, 284 passed (AC 1–11 are pytest)
- `scripts/ios-ui-test.sh --split 2 029-mock -only-testing:…/ActivityUITests/{testActivity_studyLooksAndTimesTheSame,testActivity_bufferSurvivesRelaunchAndRetries}`: timing test ✅; the delivery test failed on a wrong assertion of mine (see Notes), fixed and rerun alone as `029-mock-delivery` ✅
- `scripts/e2e.sh 029-e2e` ✅ 11 passed, 0 failed (the 10 existing live tests + the new `_liveAPI` one; logging is now on in every live test and none changed)
- `scripts/ios-test.sh` ✅ 364 passed, 0 failed, 11 skipped (AC 12–29; a first attempt ended with xcodebuild exit 70 before any test ran, infra, the rerun was green)
- Full UI suite: not run locally (CI's job). The only `mock*` runs that log are the ones that set `LA_CARTE_ACTIVITY_URL`, so the existing mock tests are unaffected; the live tests were covered by e2e.

New tests: `ios/LaCarteUITests/ActivityUITests.swift`. `scripts/e2e.sh` starts a third private API (`LA_CARTE_ACTIVITY_API_URL`, 4 cards) so AC 32 can study without touching the other suites' decks.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1–11 | PASS (pytest) | `scripts/api-test.sh`: 284 passed. Also checked on real app payloads, see "GET /activity = MCP activity_log" |
| 12–29 | PASS (unit) | `scripts/ios-test.sh`: 364 passed, 0 failed |
| 30 | PASS | Mock deck, 3 runs: `LA_CARTE_ACTIVITY=off`, `LA_CARTE_ACTIVITY_URL=http://127.0.0.1:9` (closed port), and a hung listener (accepts, reads, never answers; it received 10 `POST /activity` in the run, so logging was really on and stuck). Element identifiers (all elements on screen + alert/sheet counts) identical on front, revealed and caught-up in all 3 modes; no alert in any of the 30 launches. Screenshots: `029-mock/study-front-activity-{off,down,hung}-light.png`, `study-revealed-activity-{off,down,hung}-light.png`, `study-caught-up-activity-{off,down,hung}-light.png`. Pixel diff vs `off`: max channel difference 1/255 (glass pill render noise), all other differences are the status-bar clock; `screen-sample.py compare … 0,40,402,874`: max offset 0 pt for all 6 pairs |
| 31 | PASS | Medians within 50 ms of `off` (table below) |
| 32 | PASS | `029-e2e`: launch 1 studied 3 cards with the activity URL on a closed port (nothing reached the API meanwhile), app terminated, launch 2 pointed at the live API. `GET /activity` listed every event **0.1 s** after relaunch: card_shown, answer_revealed, rated once each for the 3 cards, plus the 4th card's card_shown, 14 events, 14 unique ids, `app_version` "1.0", `build` "1", `tz` "Europe/Paris" (device zone), `local_at` and `received_at` set. Screens: `029-e2e/study-front-activity-live-launch1-light.png`, `study-front-activity-live-launch2-light.png` (harbor, "1 new") |

### AC 31 timings (ms, from `029-mock`, 10 rounds, mode order rotated each round)
Measured in the UI test from the tap (coordinate resolved before the clock starts) until `study.back` shows the answer / `study.front` shows the next card, polled every 5 ms. XCUITest's own tap cost (~350 ms) is in every sample equally.

| Mode | reveal median (n=30) | Δ vs off | rate → next median (n=20) | Δ vs off | rate → caught-up median (n=10) |
|---|---|---|---|---|---|
| off | 378.0 (p25 366, p75 568) | — | 402.0 (p25 362, p75 493) | — | 371.5 |
| down (closed port) | 372.5 (p25 360, p75 432) | −5.5 | 362.5 (p25 359, p75 402) | −39.5 | 362.5 |
| hung server | 368.0 (p25 362, p75 416) | −10.0 | 364.5 (p25 358, p75 370) | −37.5 | 359.0 |

Logging never made the flow slower; `off` was the noisiest (the Mac was shared with other agents' simulators). A first 5-round run (`n` = 15/10) also showed `off` slowest and failed the 50 ms bar on noise (off rate→next 455 vs down 369.5), which is why the test now uses 10 rounds and pre-resolved tap points.

### Delivery (mock, `029-mock-delivery`, `testActivity_bufferSurvivesRelaunchAndRetries`)
Launch 1 studied 3 cards with the activity server unreachable; terminate; launch 2 against a stub that answers the first `POST /activity` with 500 and the rest with 200.
- Buffer survived the kill: launch 1's 3 card_shown / 3 answer_revealed / 3 rated arrived after relaunch.
- POST sizes `[200, 200, 200, 9]`: batches of at most 200, oldest first (the simulator's file still held ~400 events from the earlier runs).
- The 500'd batch (200 ids) came back with the same ids after a foreground; 409 ids acknowledged, 409 unique (no id acknowledged twice). No alert after the failed upload.

### GET /activity = MCP activity_log (real app payloads)
The 20 unique events from the mock delivery run, posted to a fresh local API:
```
POST 1: {'stored': 20, 'duplicates': 0, 'rejected': 0}
POST 2 (same batch): {'stored': 0, 'duplicates': 20, 'rejected': 0}
GET /activity: 20 events; MCP activity_log: 20 events
identical (same order, same fields): True
activity_log(card_id=<one rated card>) kinds, newest first: ['rated', 'answer_revealed', 'card_shown']
sample rated event: {"id": "3e96869b…", "kind": "rated", "at": "2026-11-25T23:11:40.612000Z",
  "local_at": "2026-11-26T00:11:40.612000+01:00", "tz": "Europe/Paris", "session": "3bff7561…",
  "card_id": "00000000…", "app_version": "1.0", "build": "1", "os": "iOS 27.0",
  "data": {"input": "button", "ms_to_rate": 383, "ms_to_reveal": 347, "rating": "good"},
  "received_at": "2026-11-25T23:17:29.765106Z"}
```
No free text anywhere in the payloads: card events carry ids, `type`, field names (`prompt: ["front"]`), counts and durations only.

## Visual review
No new screen. The three modes are pixel-identical apart from the clock (see AC 30); front, revealed and caught-up full screens checked by eye, nothing extra (no banner, alert or spinner). Light only, per the spec.

## Bugs
None.

## Notes for the architect (not blocking)
1. **The first card of a launch can sit in a different session than its reveal and rating.** Decision 10 creates a session at launch and a new one at every `app_foreground`, including the first. On the mock deck the first `queue_fetched` + `card_shown` are logged before scene `.active` (session A, 1 ms long), then `app_foreground` starts session B where the reveal and rating land (seen in `029-mock-delivery`: `E6DDA0 queue_fetched, card_shown` → `3BFF75 app_foreground, …`). On the live API the order was the other way (all in one session). An agent filtering `activity_log(session=…)` can miss the first `card_shown`. Option: don't rotate the session on the first `app_foreground` after launch.
2. **The launch fetches the queue twice** (two `queue_fetched` 25 ms apart, at launch and on `.active`). Existing behavior, now visible in the log; the second fetch correctly logs no second `card_shown` (AC 22).
3. AC 32's "events of both sessions": a launch-2 `card_shown` is not expected within 15 s (lazy flush, decision 6: 25 events or 60 s); launch 2 delivers launch 1's buffer at once (0.1 s). The test checks launch 1's events only.

## Tooling request
Timing UI flows from XCUITest carries ~350 ms of tap overhead and bimodal noise when other agents load the Mac; a 50 ms bar needs 20–30 samples per mode. A recording-based "tap to first changed frame" measure (touch indicator in the recording + `image-ops.py track`) would give real latency with fewer launches.
