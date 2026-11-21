# QA: 006 Refresh (pull-to-refresh + reload on foreground)

Verdict: PASS
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27
Runs: `qa/screenshots/006-mock/` (full UI suite, including the new tests), `qa/screenshots/006-e2e/`
Commands: `scripts/ios-ui-test.sh 006` was run as `006-mock` (✅ 64 passed, 0 failed, 6 live tests skipped as designed;
this is also the full-suite regression run for specs 000–006). `scripts/e2e.sh 006-e2e` (✅ 6/6, including the new
`testStudy_pullToRefresh_liveAPI`).
Unit tests (`scripts/ios-test.sh`): ✅ 88 checks / 7 suites, run on a clean HEAD export with only the six 006 files applied
(see the note under Bugs on why).

## What QA added
- `ios/LaCarteUITests/RefreshUITests.swift` (new, 9 tests):
  - `testStudy_pullToRefreshWhenCaughtUp`
  - `testStudy_pullToRefreshWhenOffline`
  - `testStudy_pullToRefreshWhileStudying`
  - `testStudy_pullFromEmptyCardArea`
  - `testStudy_foregroundReload`
  - `testDeck_pullToRefresh`
  - `testDeck_foregroundReload`
  - `testStudy_refreshSpinnerForest`
  - `testStudy_pullToRefresh_liveAPI`
- `StubAPIServer.swift`: `StubDeck.add(_:)` and `remove(id:)` simulate an agent adding a card or another device
  removing one. `readDelay` slows the GET routes so the refresh can be observed while it is in flight.
- `Support.swift`:
  - `pullToRefresh(_:from:)`
  - `backgroundAndReactivate(_:)` (Home, then `app.activate()`)
  - `pullToRefreshCapturing(…)`: XCUITest's drag only returns once the app is idle again, which is after the
    refresh has finished. The in-flight state (spinner, content kept on screen) is therefore captured by a screenshot
    taken from a background thread 2s into the gesture.
- `DeckUITests.swift`: `Pixels` gained an `init(CGImage, pointWidth:)`.
- `scripts/e2e.sh`: `RefreshUITests/testStudy_pullToRefresh_liveAPI` added before `testStudy_revealRateToCaughtUp_liveAPI`.
  It adds `chien` and deletes it again, so it is deck-neutral.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `study-caught-up-before-refresh-{light,dark}` → `study-refresh-spinner-{light,dark}` (captured mid-refresh with a 5s stub delay: "All caught up / Your deck is empty" stays on screen under the gray spinner, pixel-checked for ink text, so there is no blank loading state) → `study-after-refresh-{light,dark}` (`chien` unrevealed, "1 to review", no rating buttons) |
| 2 | PASS | `study-offline-before-refresh-{light,dark}`: "Can't reach your deck" with the message centered. A pull while the stub is still down stays offline. Stub up, then pull on `study.message` → `study-offline-after-refresh-{light,dark}` (`merci`, "1 to review", `study.retry` gone) |
| 3 | PASS | `testStudy_foregroundReload`: `chien` revealed, then `chat` added, Home, reactivate → `study-foreground-revealed-light` ("2 to review", back `dog` and the 4 rating buttons still shown and enabled). Then `chien` removed on the stub, Home, reactivate → `study-foreground-changed-light` (`chat` unrevealed, "1 to review") |
| 4 | PASS (unit) | `refreshIsIgnoredWhileARatingIsInFlight`, plus `ratingCancelsALoadInFlightSoTheRatedCardCantComeBack` |
| 5 | PASS | UI: stub caught up, add a card, Home, reactivate → `study-foreground-caught-up-light` (`chien`, "1 to review"). Unit: `onlyBecomingActiveReloads` (`.inactive`/`.background` do nothing) |
| 6 | PASS (unit) | `aNewLoadCancelsTheOneInFlight` |
| 7 | PASS | Caught up and offline: see #1 and #2. Studying: a pull on `study.card` (short card) shows the spinner above the card with `chien` still drawn (`study-card-refresh-spinner-{light,dark}`), then "2 to review", still unrevealed (`study-card-after-refresh-{light,dark}`). After settling, the front is back at the same y (±0.5pt), and a later reveal still doesn't move it. `testStudy_pullFromEmptyCardArea`: a pull starting 40pt below the top of `study.card`, more than 100pt above the text, also refreshes without revealing (`study-pull-card-top-light`), so the whole card area is the pull surface |
| 8 | PASS | `deck-empty-before-refresh-{light,dark}` ("No cards yet", centered) → pull on `deck.message` → `deck-after-refresh-{light,dark}` (`deck.row.<chien>`, sheet still open). With query "ch": during the refresh the `chien` row stays drawn under the spinner (`deck-refresh-spinner-{light,dark}`). After it, `chat` is added, `merle` (no match) is not shown, the field still reads "ch", and every refresh `GET /cards` carried `query=ch` (`deck-after-refresh-query-{light,dark}`). Unit: `pullingReloadsWithTheQueryKeepingRowsUntilTheResponse` |
| 9 | PASS | Deck open on "No cards yet", add a card, Home, reactivate → `deck-foreground-light` (new row). Closing the deck shows Study already updated ("1 to review", `chien`), which matches the rule that Study refreshes on foreground under a sheet. Unit: `onlyBecomingActiveReloadsWithTheQuery` |
| 10 | PASS (unit) | Exhaustive `TestStore` in `pullingReloadsWithTheQuery…` / `onlyBecomingActiveReloadsWithTheQuery`: no `delegate` received and `query` unchanged |
| 11 | PASS | Spinner is system gray, never blue. Pixel scan (no pixel with B > R+60 and B > G+30) of every in-flight capture: `study-refresh-spinner-{light,dark}`, `study-card-refresh-spinner-{light,dark}`, `deck-refresh-spinner-{light,dark}`, `study-refresh-forest-light`, `deck-refresh-forest-light`. Visually: light gray on light, mid gray on dark and forest |
| 12 | PASS | `006-e2e/deck-refresh-live-light.png`: after `POST /cards chien/dog` from the runner, a pull on the list shows `chien` at the top above `merci` and `bonjour`. `006-e2e/study-refresh-live-light.png`: deck closed, Study pulled → "3 to review", front still `bonjour`. `chien` was then deleted via `DELETE /cards/{id}` and the API deck is back to {bonjour, merci}; the later `testStudy_revealRateToCaughtUp_liveAPI` ("2 to review") passed |

## Visual review (docs/design-system.md checklist)
- [x] Background is edge to edge in light, dark and forest, including in the pulled state (the gap above the content is
  `Theme.background`, not white or system gray).
- [x] Nothing competes with the centered text, and there is no default blue tint: the spinner is gray in all three
  themes. Caught up, offline and "No cards yet" are still centered in the content area with no layout shift at rest
  (`assertCenteredMessage` plus screenshots).
- [x] Circle buttons are aligned at 44pt and unchanged.
- [x] Long text wraps with no truncation: unchanged, and the XL long/very-long card tests in `StudyUITests` still pass
  (the card still scrolls and the rating row stays pinned).
- [x] Dynamic Type XL is fine: the existing XL / XXXL suites pass.

No regressions from removing `scrollBounceBehavior` or from wrapping the states in a `ScrollView`: all 55 earlier
UI tests pass in the same run.

## Bugs
None for 006.

Note, not a 006 bug: at 13:38, during this validation, an untracked `ios/LaCarteKit/Sources/DesignSystem/LaCarteLogo.swift`
appeared in the working tree. It is concurrent design-lead work, not part of this spec. With it present,
`scripts/ios-test.sh` fails to compile:
`LaCarteLogo.swift:9:34: error: conformance of 'LaCarteLogo' to protocol 'Animatable' crosses into main actor-isolated code`.
That is why the 006 unit tests were run on a clean HEAD export with the six 006 files applied. Whoever owns the logo work
must fix this before `scripts/ios-test.sh` is green on the shared tree.
