# QA: 028 Card list labels that match the study queue

Verdict: **PASS**. This was checked on GitHub CI, because local simulators were broken on 2026-11-26 and the user
approved checking on CI instead. Bug 1 from the previous re-check is fixed: `deck.row.<id>.photo` is the thumbnail
again (ea52ee7 gives the row Button its own identifier), and `testNoteEditor_personCreateEditDelete` passes.
Date: 2026-11-26 · CI simulator: iPhone 17 Pro · GitHub Actions run 45884849522 on branch `ci-028` at b13d48c
(this branch at ea52ee7 merged with main's CI fixes; `git merge-base --is-ancestor ea52ee7 origin/ci-028` holds).

## Runs (CI run 45884849522, attempt 2: one flaky unit test from 029 was re-run)
| Job | Result |
|---|---|
| API (ruff + pytest), API (docker build) | ✅ |
| iOS unit tests | ✅ (after re-running the unrelated flaky 029 unit test) |
| iOS UI (deck-settings-study) | ✅ 43 passed, 5 skipped (live tests skip in mock), `** TEST EXECUTE SUCCEEDED **`. `testDeck_contextMenu` failed once ("no deck.row.<id>.edit after a long press", `DeckUITests.swift:471`) and passed on retry (`-retry-tests-on-failure`). See Notes. |
| iOS UI (notes-logo-milestones) | ✅ 17 passed, 3 skipped (live) |
| iOS UI (theme-ratings-report) / (rest) / (setup-widget) | ✅ 30 / 15 / 16 passed, no failures |
| iOS E2E (live API) | ✅ 12 passed, 0 failed |

028 tests in this run:
- Mock (`deck-settings-study`): `testDeckLabels_everyLabel`, `testDeckLabels_afterRatingGood`,
  `testDeckLabels_buriedSibling`, `testDeckLabels_reported`, plus the existing row tests (`testDeck_rowsFromAPI`,
  `testDeck_openFromStudy`, `testDeck_editRow`, `testDeck_swipeToDelete`, …). All passed.
- Mock (`notes-logo-milestones`): `testNoteEditor_personCreateEditDelete` passed. This is the bug 1 check: the
  `deck.row.<id>.photo` frame, its label and its position left of the name. `testNoteEditor_basicBothDirections`
  passed. The 7 NotesUITests tests that did not run in the previous re-check all passed here (`testNotesDeck_listAndSearch`,
  `testNotesStudy_photoPromptMock`, `_photoAnswerAndEmptyFieldSkipped`, `_personTextLayout`, `_personCaption`,
  `_personRevealMotion`, `_personRevealMotionReduced`).
- Live (`iOS E2E`): `testDeckLabels_matchStudy_liveAPI`, `testDeck_addFromStudyThenDelete_liveAPI` and
  `testNoteEditor_personCreateDelete_liveAPI` passed.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1-7 | PASS (pytest) | CI job "API (ruff + pytest)" green. Live check: `testDeckLabels_matchStudy_liveAPI` passed. |
| 8-10 | PASS (unit) | CI job "iOS unit tests" green. |
| 11 | PASS | `assertRow` checks the exact `deck.row.<id>.due` text in every 028 test. `.state` reads "2 directions" only on 2-card rows (`testDeckLabels_buriedSibling`). On screen: one-card rows have nothing on the right, and 2-card rows read "2 directions" (`deck-sibling-buried-light.png`, `deck-person-added-dark.png`). |
| 12 | PASS | `testDeckLabels_afterRatingGood`, light + dark. `deck-after-rating-{light,dark}.png`: serendipity "Tomorrow", la carte "New", ephemeral "New". |
| 13 | PASS | `testDeckLabels_buriedSibling`. `deck-sibling-buried-light.png`: la carte "Tomorrow" with "2 directions" (the clock-dependent case allowed by AC 13, never In queue/New). |
| 14 | PASS | `testDeckLabels_reported`. `deck-reported-light.png`: serendipity "Reported", la carte and ephemeral "New". |
| 15 | PASS | `testDeckLabels_everyLabel`, light + dark. `deck-labels-{light,dark}.png`: In queue, New, Later today, Tomorrow, In 3 days, In 2 weeks. `deck-labels-bottom-{light,dark}.png` adds In 4 months and Reported, so all 8 labels are covered. |
| Live | PASS | `ci-e2e/deck-labels-live-light.png`: flagged "Reported", fresh "New", sibling "Later today" with "2 directions". |
| Bug 1 (previous) | FIXED | `testNoteEditor_personCreateEditDelete` passed. `deck-person-added-dark.png`: 44 pt photo on the left, then "New" / Sam Rivera / runs the flower stall, and "2 directions" on the right. |

Screenshots checked (full screens, from the CI artifacts `screenshots-deck-settings-study/ci-deck-settings-study/`,
`screenshots-notes-logo-milestones/ci-notes-logo-milestones/` and `screenshots-e2e/ci-e2e/`): `deck-labels-light`,
`deck-labels-dark`, `deck-labels-bottom-light`, `deck-labels-bottom-dark`, `deck-after-rating-dark`,
`deck-sibling-buried-light`, `deck-reported-light`, `deck-person-added-dark`, `deck-labels-live-light`.

## Visual review (docs/design-system.md checklist)
- [x] Background runs edge to edge in light and dark. The row layout is the same as before the fixes: meta line,
  then front, then back, with even gaps between the cards and no default blue tint.
- [x] The meta label is secondary ink and smaller than the front, and reads clearly in both themes. The 2-card meta
  ("2 directions") is right-aligned on the same line, and one-card rows have no gap on the right.
- [x] Person row: the photo is vertically centred on the 3 text lines, and the text column is aligned.
- [x] The collapsed title and search field on scroll (`deck-labels-bottom-*`) blur the content underneath and don't overlap any label.
- [ ] Dynamic Type / VoiceOver: deferred (no accessibility tests for now).

## Bugs
None.

## Not verified / gaps
- These screenshots come from the CI run, not from a local run. No local `scripts/ios-ui-test.sh` or `scripts/e2e.sh`
  run on this exact commit, because local simulators were stuck. CI runs the same scripts (`ci/ui-test.sh scripts/ios-ui-test.sh …`).
- CI ran `ci-028` (b13d48c), which is this branch merged with main's CI fixes. It did not run this branch's own head.
  Merging this branch into main should give the same tree as `ci-028`, apart from main commits newer than the merge.
- The labels were not measured with `screen-sample.py` (contrast and spacing). The layout is unchanged from the
  first QA pass. The visual review above was done by eye on full screens.
- `deck-sibling-buried` and `deck-reported` are light-only, which is how the tests are designed. The full label set
  (AC 15) and the after-rating list (AC 12) have both themes.

## Notes
- `testDeck_contextMenu` failed once in this run, then passed on retry. It is not a 028 criterion. Because 028
  changed the row's accessibility tree, watch it on main CI: if it fails again, file a bug about the timing of the
  context-menu long press on `deck.row.<id>`.
