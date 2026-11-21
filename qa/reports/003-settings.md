# QA: 003 Server settings

Verdict: PASS
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27
Runs: `qa/screenshots/003-mock/` (full UI suite), `qa/screenshots/003-e2e/`
Commands: `scripts/ios-ui-test.sh 003-mock` (✅ 47 passed, 4 live tests skipped as designed), `scripts/e2e.sh 003-e2e` (✅ 4/4),
full suite (✅, same run as 003-mock: specs 000, 001, 002, 003)

Tests: `ios/LaCarteUITests/SettingsUITests.swift` (new), `DeckUITests.swift` (delete tests moved to `deck.row.<id>.delete`,
plus `testDeck_swipeToDeleteDark` and `testDeck_deleteReloadsWithQuery`), `Support.swift` (`APIMode.stored`: launch with
no API env), `StubAPIServer.swift` (records request headers so tests can check the token is sent).
`scripts/e2e.sh` now also runs `SettingsUITests/testSettings_setupOnDevice_liveAPI`.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `003-mock/deck-with-settings-{light,dark}.png`, `settings-{light,dark}.png`. `testSettings_openFromDeckAndClose`: gear is 44pt, on the title line, just left of `deck.add`; sheet has title "Settings", `settings.url` (text field), `settings.token` (secure text field, placeholder "Token (optional)"), "Test connection", 44pt `settings.close` top-right on the title line |
| 2 | PASS (UI part) | URL placeholder "http://127.0.0.1:8000" (`settings-xl-light.png`); the typed URL is shown again after a relaunch (`settings-relaunched-light.png`). URL keyboard (`/`, `.com`, lowercase) in `003-e2e/settings-live-unreachable-light.png`. Storage itself is unit-validated |
| 3 | PASS (UI part) | `testSettings_persistAcrossRelaunch`: after a relaunch the token field is a secure field whose value has the token's length, masked. The relaunched app sends `Bearer <token>` on every request. Keychain delete-on-empty is unit-validated |
| 4 | PASS | `settings-checking-light.png` ("Checking…", stub `/stats` delayed 5s), `settings-connected-light.png` ("Connected · 3 cards", mock), `settings-unauthorized-light.png` ("Wrong token", stub 401; the request carried `Bearer wrong`), `settings-unreachable-light.png` ("Can't reach server": nothing listening on :9, and also an HTTP 500) |
| 5 | PASS | `testSettings_checkingThenConnectedThenEditClears`: deleting one URL character, and later typing in the token, both remove the status |
| 6 | PASS (UI part) | With no launch env, requests go to the URL and token typed in Settings, also after a relaunch (`testSettings_persistAcrossRelaunch`, `testSettings_tokenSavedOnSwipeDismiss`, e2e). Env precedence is unit-validated |
| 7 | PASS | `testSettings_successReloadsDeckAndStudy`: switching server A → B: each successful test triggers `GET /cards` on the new server while the sheet is still open; the deck then shows the new rows and study shows the new card (`study-after-server-change-light.png`: "bravo", "2 to review") |
| 8 | PASS | `testSettings_openFromDeckAndClose`: `settings.close` and a swipe-down both return to "Cards", light and dark. A token typed and then swiped away (no Close, no Test) is still stored after a relaunch |
| 9 | PASS | `003-e2e/settings-live-connected-light.png` ("Connected · 2 cards"), `settings-live-wrong-token-light.png`, `settings-live-unreachable-light.png`. After restoring the real values, study shows the seeded "bonjour", "2 to review" (`study-live-after-settings-light.png`) and again after a relaunch with no env |

Spec 003's Deck changes (regression):
- `deck.row.<id>.delete` exists with label "Delete". Pixel checks confirm a system-red fill in light and dark (`003-mock/deck-swipe-{light,dark}.png`).
- Deleting while a search is active reloads with `query=a` and sends no unfiltered `GET /cards`, so the list keeps matching the field (`deck-delete-while-searching-light.png`).
- A failed DELETE still reloads, and the deleted current card leaves study (`deck-delete-failed-light.png`, `study-after-delete-light.png`).

## Visual review (docs/design-system.md checklist)
- [x] Background is edge to edge in light and dark. The sheet background is `background`, and both field rows are `surface` (pixel-checked).
- [x] No default blue tint. "Test connection" is ink (pixel-checked), and the status line is `.meta` secondaryInk.
- [x] Circle buttons are 44pt and aligned. The gear and add buttons share the title line. The close button matches the editor sheet: same title and close position (compared with `editor-new-light.png`), and the same ref-03 feel.
- [x] No truncation. Labels are short; URLs up to the field width show in full.
- [x] Dynamic Type at accessibility XL works (`settings-xl-*.png`, `settings-xl-connected-*.png`): rows grow and nothing clips or overlaps.

Design judgement: the screen is calm and matches the spec's layout (title, "Server" caption, two surface rows of radius 12, a quiet ink text button, then a grey status). The large empty space below fits, since spec 004 adds Appearance there.

Not bugs (screen-capture artefacts):
- The token row looks empty in every screenshot, and the keyboard area is plain white while the token field has focus. iOS leaves secure-field content and the secure-entry keyboard out of screen captures. XCUI confirms the field holds the masked token.

## Bugs
None blocking.

Minor observation, non-blocking (for the engineer's backlog):
1. **The right edge of the settings field rows doesn't focus the field.** Steps: open Settings and tap the URL row about 6pt from its right edge (row x 24–378; tap at x≈367). Expected: the URL field gets focus, as it does anywhere else in the row. Actual: nothing happens. Taps at 85% of the width or less focus the field. The accessibility frame covers the whole 354pt row, so the inner padding isn't a tap target. The token row probably behaves the same (not probed). Fix: make the whole row the tap target, for example with `.contentShape` plus a focus binding. Found with a probe test; no screenshot.
