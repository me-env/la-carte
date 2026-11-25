# QA: 027 Note editor: new basic notes check both directions

Verdict: PASS
Date: 2026-11-25 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-ad5879c6f03026a9f` (impl 25dd485)
Runs: `qa/screenshots/027-mock/`, `qa/screenshots/027-e2e/`
Commands: `LACARTE_AGENT=qa-027 scripts/ios-ui-test.sh --split 027-mock -only-testing:LaCarteUITests/NotesUITests -only-testing:LaCarteUITests/DeckUITests`
(✅ 26 passed, 0 failed, 3 skipped = the `_liveAPI` tests), `LACARTE_AGENT=qa-027 scripts/e2e.sh 027-e2e` (✅ 10 passed, 0 failed; `testDeck_addFromStudyThenDelete_liveAPI` unchecks back-front, `027-e2e/deck-live-light.png` shows feline/cat "new"). Full suite: CI's job
(only affected classes run locally).

Every screenshot cited is the whole device screen (1206 × 2622 px), never a crop.

## Tests
- New `NotesUITests.testNoteEditor_basicBothDirections` (stub API, light + dark): AC 12, 8 (UI side), 9, 10, 11, 4.
- `NotesUITests.testNoteEditor_personCreateEditDelete`: `back-front` assertion flipped (AC 9), retakes `editor-basic-new`.
- `DeckUITests.testDeck_addFromDeck`, `testStudy_addWhenCaughtUp`, `testDeck_changesRefreshStudy`,
  `testDeck_addFromStudyThenDelete_liveAPI`: new helper `keepOnlyFrontToBack` asserts `back-front` on by default,
  taps it off, asserts `front-back` still on (AC 3 end to end); existing one-card assertions ("new", "1 new", "3 new") pass.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS (unit) | `NoteEditorFeatureTests` in 25dd485; UI side: `027-mock/editor-basic-new-light.png` |
| 2 | PASS | unit; UI: POST /notes directions `[[front],[back]]` asserted in `testNoteEditor_basicBothDirections` |
| 3 | PASS | unit; UI: `027-mock/editor-basic-one-direction-light.png`, 4 Deck tests uncheck back-front and save one card |
| 4 | PASS | `027-mock/editor-basic-no-direction-light.png` / `-dark.png`: both unchecked, Save greyed, `editor.directionsHint` = "Choose at least one direction" (asserted) |
| 5 | PASS (unit) | TestStore; UI side covered by AC 12 |
| 6 | PASS (unit) | TestStore |
| 7 | PASS | `027-mock/editor-person-new-directions-light.png` / `-dark.png` (no direction on, asserted) |
| 8 | PASS | unit; UI: New card at defaults → `editor.close` dismisses with no prompt (asserted) |
| 9 | PASS | `027-mock/editor-basic-new-light.png`, `editor-basic-new-dark.png`: both checkmarks, fields empty, Save greyed |
| 10 | PASS | `027-mock/deck-basic-two-directions-light.png` / `-dark.png`: "chat / cat" row reads "2 directions" |
| 11 | PASS | `027-mock/editor-basic-one-direction-light.png` (only Front → Back checked, Save enabled) → `027-mock/deck-basic-one-direction-light.png`: "Capital of France? / Paris" reads "new"; POST directions `[[front]]` |
| 12 | PASS | `027-mock/editor-basic-edit-one-card-light.png` / `-dark.png`: "Edit card" greeting/hello, only Front → Back checked |
| 13 | PASS (unit + review) | engineer's `scripts/ios-test.sh` run in 25dd485; renamed/updated tests present, none deleted |

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark (all editor and deck shots)
- [x] nothing competes with the content, no default blue tint (checkmarks in the primary ink colour)
- [x] circle buttons aligned (Close leading, Save trailing, same line); Save greyed when it can't save
- [x] long text wraps, no truncation ("Capital of France?" fits)
- [ ] Dynamic Type XL: deferred (no AX checks for now)

Observation (pre-existing, not 027: "no layout change"): with the keyboard up, the Directions footer
("Each direction is its own card." / "Choose at least one direction") sits half under the keyboard top edge
(`027-mock/editor-basic-no-direction-light.png`). Same as 014c; it scrolls into view. Not blocking.

## Bugs
None.
