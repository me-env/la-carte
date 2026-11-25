# QA: 028 Card list labels that match the study queue

Verdict: **FAIL** (one bug: the `deck.row.<id>.due` identifier on one-card rows. The labels themselves are right everywhere.)
Date: 2026-11-26 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-ad9dd16678ae32684` (API d50f182 + iOS ec6e25f)
Runs: `qa/screenshots/028-mock/` (DeckUITests + NotesUITests), `qa/screenshots/028-labels/`, `qa/screenshots/028-labels2/`
(the new 028 tests), `qa/screenshots/028-e2e/`
Commands: `scripts/ios-ui-test.sh --split 028-mock -only-testing:…/DeckUITests -only-testing:…/NotesUITests` (❌ 24 passed,
7 failed: all bug 1), `scripts/e2e.sh 028-e2e` (❌ 9 passed, 2 failed: all bug 1), `scripts/api-test.sh` (✅ ruff + 268 passed).
The full UI suite was not run: only the affected classes, as the task asked (no other class asserts row labels).

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1-7 | PASS (pytest) | `scripts/api-test.sh` green. Live cross-check in `testDeckLabels_matchStudy_liveAPI`: the reported note's `next` is `null`. The sibling's `next.ready_at` comes after the review and within 6 h. `GET /cards/due` holds only the "fresh" note. |
| 8-10 | not re-checked (unit, engineer) | The mock runs agree with Study. In `testDeckLabels_everyLabel`, Study serves "in queue", then "new", then "All caught up" (`028-labels2/study-labels-caught-up-light.png`). |
| 11 | **FAIL** | The visible text is right: one-card rows show no right-side text, and 2-card notes show "2 directions" (`028-labels/deck-sibling-buried-light.png`, `028-e2e/deck-labels-live-light.png`). The identifier is wrong: on a one-card row, `deck.row.<id>.due` is a full-row **Button** (frame 0,238,402×104). Its label is the whole row, e.g. `New, serendipity, finding something good without looking for it`, not `New`. See bug 1. |
| 12 | PASS on screen, FAIL in the test (bug 1) | Every row first reads New, as the label assert's prefix shows. After rating the first card Good: serendipity reads Tomorrow and the others read New (`028-labels/deck-after-rating-light.png`, `-dark.png`). |
| 13 | PASS | la carte reads "Later today" with "2 directions" and never In queue or New (`028-labels/deck-sibling-buried-light.png`, test passed). |
| 14 | PASS on screen, FAIL in the test (bug 1) | serendipity reported from Study → its row reads "Reported" (`028-labels/deck-reported-light.png`). |
| 15 | PASS on screen, FAIL in the test (bug 1) | The rows read In queue, New, Later today, Tomorrow, In 3 days, In 2 weeks, In 4 months and Reported. Screenshots: `028-labels2/deck-labels-light.png` + `deck-labels-bottom-light.png`, and the `-dark` pair. The 8 rows (104 pt each) don't fit one screen: 6 show, and the last 2 show after one scroll. The spec's "all rows visible" needs 2 screenshots. |
| Live | PASS on screen, FAIL in the test (bug 1) | `028-e2e/study-live-after-sibling-light.png` shows that after rating sibling Good, Study serves "fresh", not the buried sibling and not the reported card, with counter "1 new". `028-e2e/deck-labels-live-light.png`: flagged reads "Reported", fresh reads "New", and sibling reads "Later today" with "2 directions". |

## Visual review (docs/design-system.md checklist)
- [x] Background edge to edge in light and dark. Row layout is unchanged: meta line on top, front, back.
- [x] Nothing competes and there's no default blue tint. The labels are secondary ink, same as before.
- [x] With the state text gone, one-card rows show nothing on the right, with no gap or misalignment.
- [x] Long backs truncate on one line as before (serendipity).
- [ ] Dynamic Type: deferred (no accessibility tests for now).

## Bugs
1. **`deck.row.<id>.due` points at the whole row on one-card notes.** Steps: run with `LA_CARTE_API=mock`, open the
   deck, and query `deck.row.00000000-0000-0000-0000-000000000001.due`. Expected: the meta-line Text, label `New`
   (spec 028 #11, "Accessibility identifiers"). Actual: a Button 402×104 pt covering the row, with label
   `New, serendipity, finding something good without looking for it`. Rows with 2+ cards are fine: they still have
   the `.state` Text next to the label, as with la carte in `028-labels/deck-sibling-buried-light.png`. This started
   when the `.state` Text became conditional (`DeckView.swift` ~177-183). With only the due Text left in the meta
   HStack, its identifier ends up on the row's button. This fails 7 mock tests (`testDeck_openFromStudy`,
   `testDeck_rowsFromAPI`, `testDeck_addFromDeck`, `testDeckLabels_everyLabel`, `testDeckLabels_afterRatingGood`,
   `testDeckLabels_reported`, `NotesUITests/testNoteEditor_basicBothDirections`) and 2 e2e tests
   (`testDeck_addFromStudyThenDelete_liveAPI`, `testDeckLabels_matchStudy_liveAPI`). Fix: the due Text must stay its
   own element with its own label on every row.

## Notes (not blocking)
- In the `mock-labels` deck, the Study counter reads "5 to review" while Study serves only 2 cards. That count comes
  from the mock's spec-021 ladder, not from 028. The live API's counter agrees with the queue ("1 new").
- Test-side changes: `APIMode.mockLabels`. `StubDeck` notes now carry `next` (the earliest-due card, as the server
  does without bury or reports). `assertRow(state: nil)` checks that the state text is absent. `e2e.sh` runs
  `testDeckLabels_matchStudy_liveAPI` on the empty API (net zero).
