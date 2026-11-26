# QA: 028 Card list labels that match the study queue

Verdict: **FAIL** (re-check of the fix 81ad98d / 784c897). The previous bug is fixed: `deck.row.<id>.due` is its own
element on every row. The fix causes a regression: on person rows, `deck.row.<id>.photo` is now the whole row button
(bug 1). Some screenshots are still missing, because local UI runs stopped working partway through (see "Left for CI").
Date: 2026-11-26 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-ad9dd16678ae32684` at 784c897 (main merged at 7e1eb98)

## Runs (this re-check)
| Command | Result |
|---|---|
| `scripts/api-test.sh` | ✅ ruff + 268 passed (no API change since d50f182; re-run after the main merge) |
| `scripts/e2e.sh 028-recheck-e2e` | ✅ 11 passed, 0 failed (`qa/screenshots/028-recheck-e2e/`) |
| `scripts/ios-ui-test.sh 028-recheck -only-testing:…/DeckUITests -only-testing:…/NotesUITests` | ❌ DeckUITests **22/22 passed** (2 live tests skipped, as expected in mock). NotesUITests: `testNoteEditor_basicBothDirections` passed, **`testNoteEditor_personCreateEditDelete` failed** (bug 1). Then the runner hung at 0% CPU (fseventsd) and the run was killed, so its screenshots were never exported. 8 NotesUITests tests did not run. |
| 4 retries of the remaining tests | No result. Two builds stalled (the `_lock.sh` guard killed them, exit 124), the simulator audio service was stuck, and one test runner died with Mach -308. The manager then stopped local runs until the reboot. |

The previous run, before the fix (`qa/screenshots/028-mock/logs/NotesUITests_testNoteEditor_personCreateEditDelete.txt`),
passed `testNoteEditor_personCreateEditDelete`. So the failure is new and comes from the fix.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1-7 | PASS (pytest) | `scripts/api-test.sh` green. Live: `testDeckLabels_matchStudy_liveAPI` passed (see the Live row). |
| 8-10 | PASS (unit, engineer) | Unit tests are in the fix commit (`queueLabelWithoutNextFromAnOlderServer`, mock stats). The mock runs agree with Study: `testDeckLabels_everyLabel` passed (Study serves only "in queue" and "new", then "All caught up"). |
| 11 | PASS (fixed) | `deck.row.<id>.due` reads exactly the label on one-card rows. `assertRow` matches the exact label, and every 028 test and `testDeck_rowsFromAPI` / `openFromStudy` / `addFromDeck` passed. `.state` is absent on one-card rows and reads "2 directions" on 2-card rows (`testDeckLabels_buriedSibling` passed). |
| 12 | PASS (test) · screenshot left for CI | `testDeckLabels_afterRatingGood` passed in light + dark (all rows read New, then Tomorrow / New / New). Visuals from the previous run: `qa/screenshots/028-labels/deck-after-rating-{light,dark}.png`. |
| 13 | PASS | `testDeckLabels_buriedSibling` passed ("Later today", never In queue/New). |
| 14 | PASS | `testDeckLabels_reported` passed (Reported, next row New). |
| 15 | PASS (test) · screenshot left for CI | `testDeckLabels_everyLabel` passed in light + dark, with all 8 labels asserted exactly. Visuals from the previous run: `qa/screenshots/028-labels2/deck-labels{,-bottom}-{light,dark}.png`. The fix adds only an accessibility container, so the layout should be unchanged, but that still needs to be confirmed on new screenshots. |
| Live | PASS | Full screen `qa/screenshots/028-recheck-e2e/deck-labels-live-light.png`: flagged "Reported", fresh "New", sibling "Later today" with "2 directions" on the right. `study-live-after-sibling-light.png`: Study serves "fresh", with counter "1 new". |

## Visual review (docs/design-system.md checklist), on the live full screens of this run
- [x] Background edge to edge. Row layout is unchanged: meta line on top, then front, then back. 8 pt gaps between rows, no default blue tint.
- [x] One-card rows show nothing on the right, with no gap or misalignment. On 2-card rows, "2 directions" sits right-aligned on the meta line.
- [ ] Mock light/dark screenshots of this build: left for CI. The previous build's screenshots passed, and the fix is accessibility-only.
- [ ] Dynamic Type: deferred (no accessibility tests for now).

## Bugs
1. **Regression: `deck.row.<id>.photo` is now the whole row button on person rows.** Steps: run
   `NotesUITests/testNoteEditor_personCreateEditDelete` (mock). Create the person "Sam Rivera" / "runs the flower
   stall" and save. Then query `deck.row.<id>.photo` in the deck. Expected: the 44 pt thumbnail, labelled `Photo`,
   to the left of the name. Actual: an element with frame (0, 238, 402×104.3), labelled
   `Photo, Sam Rivera, runs the flower stall`. Failures at `NotesUITests.swift:115` (via `assertPersonRow`):
   "Expected label 'Photo'", "402 is not equal to 44 ± 2.5", "thumbnail not left of the name". Cause: this is the same
   mechanism as the earlier `.due` bug. 81ad98d made the meta HStack its own container
   (`DeckView.swift`, `.accessibilityElement(children: .contain)` after `.foregroundStyle(Theme.secondaryInk)`). Now the
   `CardPhoto` thumbnail is the row label's only direct leaf, so the row Button takes the photo's identifier. Fix: give
   the thumbnail its own element too (for example, its own container). Better: make the whole label HStack a single
   `.contain` container, so that no identifier inside the row can fall through to the Button.

## Left for CI (local simulators unreliable until the reboot)
- Run these again: `DeckUITests` (all) and `NotesUITests` (all), light + dark. 8 NotesUITests tests did not run after
  the hang: `testNotesDeck_listAndSearch`, `testNotesStudy_photoPromptMock`,
  `testNotesStudy_photoAnswerAndEmptyFieldSkipped`, `testNotesStudy_personTextLayout`, `testNotesStudy_personCaption`,
  `testNotesStudy_personRevealMotion`, `testNotesStudy_personRevealMotionReduced`. Also `testNoteEditor_personCreateEditDelete`
  after the bug 1 fix.
- New mock screenshots of `deck-labels`, `deck-labels-bottom` and `deck-after-rating` (light + dark), to check that the
  layout didn't move.

## Notes
- No UI test changes in this re-check. The 028 tests committed with the first QA pass (db0939b) caught both bugs as
  they are.
- Tooling: this branch's scripts predate main's 61cb49a, which skips simulators with a stuck audio service and makes the
  shim skip file coordination. Until main is merged in again, runs on this branch hit both problems.
