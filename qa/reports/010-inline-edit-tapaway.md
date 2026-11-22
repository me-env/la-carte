# QA: 010 Inline edit, tap-away recognizer (bug B fix) + 017 layout D

Verdict: **PASS**
Date: 2026-11-22 · Simulator: iPhone 17 Pro / iOS 27 · light (StudyEdit `editFront`/`editBackDone`/`saveFailure` also dark)
Build: `ca80680` on `worktree-agent-aa790f7910fc56c74` (`StudyFeature/TapAway.swift` replaces the drag gesture + cached field frame)

Runs (`qa/screenshots/`, logs in each `<run>/logs/`):
| run | command | result |
|---|---|---|
| `010-tapaway-mock/` | `--split 3 --wait --record` StudyLengthsUITests + StudyUITests + StudyEditUITests | ✅ 24 passed, 0 failed, 3 skipped (the `_liveAPI` tests; no e2e run in this scope) |
| `010-tapaway-iter/` | `testStudyLengths_inlineEditLongFront` with `-test-iterations 10` | ✅ 10 of 10 passed |
| `010-tapaway-immediate/` | `testStudyEdit_tapFieldRightAfterOpen` with an asserted immediate-tap loop (first version) | ❌ by design of that first version, see case 3 |
| `010-tapaway-new/` | the 3 new tests, final version | ✅ 3 passed |

No full suite (manager's scope: the three Study classes). No `scripts/e2e.sh` run (not requested; the live variant of the inline edit, `testStudyEdit_appendToBack_liveAPI`, is unchanged).

## Bug B (a tap inside `study.frontField` ended the edit, 1 in 6 before)
`testStudyLengths_inlineEditLongFront`: **11 of 11** passed (10 iterations + the split run). Each run taps inside the field 3 times
(`replaceText` puts the caret at the end) while editing the long Westphalia question. FIXED.

## Cases left for QA (new tests in `StudyEditUITests`)
| # | Case | Result | Evidence |
|---|---|---|---|
| 1 | Downward swipe on a card that scrolls ends the edit, and saves it | PASS | `testStudyEdit_swipeDownOnScrollingCardCommits`. Stub card: 2-line question, 14-sentence answer (overflows the ratings). Double-tap the front, type "!", then drag 200 pt down starting on the answer (off the field, above the keyboard) while the card is scrolled: field gone, keyboard gone, `study.front` = draft, ratings back, one PATCH with the draft, stub deck saved it. `010-tapaway-mock/study-edit-scrolling-card-editing-light.png` → `…-swiped-light.png`; recording strip shows the card scrolled (question partly above the top) before the swipe. An upward 120 pt drag on the answer before that (scrolling to read on) did **not** end the edit (noted, not asserted). |
| 2 | Dragging the caret or a selection in the field never ends the edit | PASS | `testStudyEdit_caretAndSelectionDragKeepEditing` (3-line back): long-press + drag sideways; long-press + drag from line 1 to line 3 (≈ 70 pt **down**, over the 30 pt swipe threshold); double-tap to select a word; drag from the selection's end down 2 lines. After each: field exists, focused, keyboard up, no ratings, no PATCH. Then edit + Done saves. `study-edit-word-selected-light.png`, `study-edit-selection-dragged-light.png` (selection extended across 2 lines, Cut/Copy menu, still editing), `study-edit-caret-dragged-light.png`. |
| 3 | Tap on the field right after the edit opens | Behaviour reported | `testStudyEdit_tapFieldRightAfterOpen`. **Tap at the field's current position**, 0.56–1.35 s after the double-tap (0, 0.15, 0.3, 0.6 s extra delay; front and back): the edit stayed open 6 of 6 (both runs). **Tap at the text's pre-edit position** with no query in between (the fastest XCUITest allows, 0.65–0.69 s after the double-tap returned): the edit ended 3 of 3. Recording (`010-tapaway-immediate/recordings/…mp4`, frames 29.7–31.3 s): the keyboard and the card's lift finish ~0.25 s after the double-tap; by the time XCUITest's tap lands (it waits for the app to idle) the field has moved ~150 pt up and the tap hits empty card area, so ending the edit is the specified tap-away. A tap **during** the lift can't be produced from XCUITest (it waits for idle), so the "ignored while moving" path is unverified on screen: left for the user on device (double-tap the answer, tap it again immediately). The test notes the immediate-tap outcome and asserts only the tap-on-the-field part. |

## Confirmations
| Item | Result | Evidence |
|---|---|---|
| Tap outside the field ends + saves the edit | PASS | `testStudyEdit_commitByTapOutsideAndKeyboardSwipe` (empty card area above the texts, and the other side's text): PATCH each time, ratings back. `study-edited-swipe-light.png` |
| Keyboard swipe-down commits | PASS | same test, third part |
| Return and Done commit | PASS | `testStudyEdit_editBackDone` (Done key, light + dark, `study-edited-light.png`), `testStudyEdit_returnCommitsWithoutNewline` (Done with the caret mid-text, typed newline), `inlineEditLongFront` (Return) |
| Rating off while editing | PASS | `assertEditingChrome` in `testStudyEdit_editFront` (light, dark, forest): no `study.rate.*`, no `study.reveal`, no counter; also asserted after every drag in case 2. `study-editing-front-light.png`, `study-edit-scrolling-card-editing-light.png` |
| Bug A (layout D: answer ink within ~0.5 pt of the question's) | PASS | `testStudyLengths_layoutD`: 2-line question ink starts 76.67, answer ink 76.50 (0.17 pt); 1-line 89 % question 37.50, answer 36.87 (0.63 pt, same as the accepted 017 re-validation run; test bound 1.1 pt). backField 76.0/250 wide vs `study.back` 76.2/249. `study-layoutD-2line-long-editing-back-light.png` |

## Visual review
- Background edge to edge, no default blue tint in the card; selection and caret use the accent (pink), menu native.
- While the front is edited, the answer keeps the saved question's column (answer ink at 23.3 pt, question's first line); after
  the save it moves once to the new widest line (19.3 pt, `screen-sample bbox` on `…-editing` vs `…-swiped`). Matches spec 017
  ("the size may change once" on save); not a bug.
- Test-environment artefact, not an app bug: right after XCUITest's `typeText`, the simulator sometimes hides the software
  keyboard for ~1.5 s and shows the hardware-keyboard bar (e.g. `study-lengths-long-editing-medium-draft-light.png`,
  `study-edit-scrolling-card-editing-light.png`: no keyboard, field still focused). It comes back on its own.

## Bugs
None.

## Tooling request
XCUITest can't send a touch while the app animates (every action waits for idle), so "a tap during the keyboard lift is
ignored" can only be checked by hand. A test hook that slows animations (e.g. a launch argument setting
`UIApplication…layer.speed` / `UIView.setAnimationsEnabled` timing ×10) would make that window testable.
