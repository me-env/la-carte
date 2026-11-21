# QA: 002 Deck list + add / edit card

Verdict: PASS
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27
Runs: `qa/screenshots/002-mock/`, `qa/screenshots/002-e2e/`
Commands: `scripts/ios-ui-test.sh 002-mock` (✅, full UI suite: 35 passed, 3 `_liveAPI` skipped), `scripts/e2e.sh 002-e2e` (✅, 3/3), full suite (✅, same run as 002-mock: no regression in 000/001)

Tests: `ios/LaCarteUITests/DeckUITests.swift` (new), `StudyUITests.testStudy_cornerButtonsTappable` (updated: the corner
buttons now open the deck and the "New card" editor), `StubAPIServer.swift` (new stateful `StubDeck` for
`/cards`, `POST`, `PATCH`, `DELETE`, with failing or delayed writes), `scripts/e2e.sh` (adds `testDeck_addFromStudyThenDelete_liveAPI`).

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `testDeck_openFromStudy` (light + dark): "Cards", rows …01/…02/…03 in order, "Due now"/"new", front and back on one line each, back in `secondaryInk`. Pixel checks: rows are `surface`, the 8pt gaps and the area around the rows are `background` (no separators, no list background), search field on `surface`. `testDeck_rowsFromAPI`: keeps the API's newest-first order, "Due in 3 days", state "review", long text truncated to 1 line, `GET /cards?limit=500`. `002-mock/deck-light.png`, `deck-dark.png`, `deck-api-rows-light.png` |
| 2 | PASS | `testDeck_search` (light + dark): "ser" leaves only serendipity; clearing shows all 3. `testDeck_searchDebounced` (stub): only `query=ser` is sent (no `s`/`se`), ≥0.3s after typing starts. `deck-search-light.png`, `deck-search-dark.png` |
| 3 | PASS | "No matches" `deck-no-matches-light.png`; "No cards yet" `deck-empty-{light,dark}.png`; "Can't reach your deck" `deck-offline-{light,dark}.png`; no rows in any of them |
| 4 | PASS | `testDeck_swipeToDelete`: swiping left reveals "Delete", and the row is gone within 1.5s and still gone after reopening. `testDeck_swipeToDeleteCallsAPI`: sends `DELETE /cards/…02`. `testDeck_deleteFailureReloads`: on a 500, a `GET /cards` follows and the row comes back. `deck-swipe-light.png`, `deck-delete-failed-light.png` |
| 5 | PASS | `testDeck_editRow` (light + dark): "Edit card" prefilled; changing the back to "short-lived" and saving closes the editor and updates the row in place. `testDeck_editRowCallsPATCH`: `PATCH /cards/…03` with the new back. `editor-edit-{light,dark}.png`, `deck-after-edit-{light,dark}.png` |
| 6 | PASS | `testDeck_addFromDeck` (light + dark): "New card", empty fields, `editor.front` has keyboard focus; saving puts "chat"/"cat" at the top. `testDeck_addCallsPOSTAndDisablesSaveInFlight`: `POST /cards` with chat/cat. `editor-new-{light,dark}.png`, `editor-filled-light.png`, `deck-after-add-{light,dark}.png` |
| 7 | PASS | `testStudy_addWhenCaughtUp`: caught up → `study.add` → "New card" (front focused) → save → study shows "chat", "1 to review". `study-after-add-light.png` |
| 8 | PASS | Save is disabled with both fields empty, with an empty back, and with a whitespace-only back, and while a slow (3s) POST is in flight. `editor-new-*.png` (dimmed check), `editor-saving-light.png` |
| 9 | PASS (UI as well) | `testEditor_saveFailureKeepsText` (light + dark): on a POST 500 the editor stays open, front/back keep their text, `editor.error` reads "Couldn't save. Check your connection." under the fields, and save is re-enabled. `editor-error-{light,dark}.png` |
| 10 | PASS | `testEditor_closeWithoutSaving`: close from study-add, deck-add, and edit-with-changes sends no POST/PATCH/DELETE; the row keeps its original back |
| 11 | PASS | `testDeck_changesRefreshStudy`: deleting the current card (serendipity) in the deck, then closing it → study shows "la carte", "2 to review"; editing the current card's front → study shows "la carta"; adding from the deck → "3 to review". `study-after-delete-light.png` |
| 12 | PASS | Swipe down closes the deck (`testDeck_openFromStudy`, `testStudy_cornerButtonsTappable`). `testDeck_accessibilityXL`: rows scale (>1.3×), deck texts don't overlap or clip, due/state stay inside the row, and editor title/fields/buttons stay in the window without overlapping. `deck-xl-light.png`, `editor-xl-light.png` |
| 13 | PASS | `testDeck_addFromStudyThenDelete_liveAPI` (real API, seeded bonjour/merci): add chat/cat from study → top row in the deck and present in `GET /cards`; swipe-delete → gone after reopening and gone from the API. `002-e2e/deck-live-light.png`, `deck-live-after-delete-light.png`. The 001 live tests still pass after it |

## Visual review (docs/design-system.md checklist)
- [x] Background is edge to edge in light and dark. Deck and editor sheets use `Theme.background`, and the pixel samples match the tokens (#F9FAF5 / #1A1A1A, rows #FFFFFF / #252525).
- [x] Nothing competes with the content, and there is no default blue tint in the app. The blue search/return key belongs to the system keyboard.
- [x] Circle buttons: `deck.add`, `editor.save`, `editor.close` are 44pt on the same top line, with xmark rightmost (ref 03). In dark mode they have the hairline border; in light mode, the soft shadow.
- [x] Long text: deck rows truncate to 1 line with an ellipsis, as the spec asks. The editor wraps long text (`editor-xl-light.png`).
- [x] Dynamic Type XL: the deck and editor reflow. At XL the editor title is taller than the 44pt buttons and sits under their top edge (top-aligned), which reads fine.
- Compared with ref 04: same feel (bold title left, round action right, surface rows with radius 12, grey meta line on top, quiet secondary text). Compared with ref 03: title top-left and round actions top-right, borderless text on paper.

## Notes (non-blocking)
1. The swipe "Delete" action is drawn in ink (near-black) instead of the system destructive red (`deck-swipe-light.png`). The spec says "a destructive Delete" without naming a colour. This fits "accent = ink", but since there is no confirmation and no undo, a red action would warn the user more clearly. This is a call for the architect or manager.
2. The swipe action has no accessibility identifier (the spec doesn't define one), so the tests find it by its label "Delete". Adding `deck.row.<id>.delete` to the spec would let tests stick to identifiers only.
3. Row identifiers use Swift's uppercase UUID form (`deck.row.AAAAAAAA-…`), while the API returns lowercase ids. This is harmless (fixtures are numeric), and the tests uppercase the ids.

## Bugs
None.
