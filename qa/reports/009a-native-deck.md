# QA: 009a Native polish — Deck sheet

Verdict: PASS (re-check de44440 + main merge; #8 fixed)
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27
Runs: `qa/screenshots/009a-deck/` (DeckUITests)
Commands: `scripts/ios-ui-test.sh 009a-deck -only-testing:LaCarteUITests/DeckUITests` (❌ 27 passed, 1 failed: #8),
full suite and `scripts/e2e.sh` **not run**: cancelled while queued on the simulator lock (manager rule: full regression runs after merge). Verdict is FAIL on the Deck class alone

## Test changes
- `Support.swift`: `deckTitle(app)` = `app.navigationBars["Cards"]`, `deckTitleText`, `deckSearch(app)` =
  `app.searchFields.firstMatch`, `waitForDeckTitle`. Every `deck.title` / `deck.search` query in all suites moved to them.
- Old chrome checks (44pt custom circles, title and add on one line, surface-filled search) replaced by the 009a layout:
  toolbar above a large left title, search under the title, rows under the search (Deck, Settings, Theme suites).
- New in `DeckUITests`: `testDeck_largeTitleCollapsesOnScroll` (#1, light/dark/forest), `testDeck_toolbarButtons` (#2,
  ink glyph and no pink, opens Settings + New card, light/dark/forest), `testDeck_searchClearButton` (#3),
  `testDeck_noMatchesSystemSearchState` (#4, light/dark/forest), `testDeck_messagesForest` (#5),
  `testDeck_contextMenu` (#6), `testDeck_searchAccentOnly` (#8, pixel check: pink only inside the search field, and present
  there), `testDeck_ax5LongRows` (#9). Old `testDeck_noMatches` removed (superseded).

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `009a-deck/deck-large-title-{light,dark,forest-light}.png` (large left "Cards"), `deck-collapsed-{light,dark,forest-light}.png` (inline centered title after scrolling) |
| 2 | PASS | `009a-deck/deck-light.png`: gear + plus in one glass capsule top-right, ink glyphs, no pink; `deck-settings-open-*.png`; New card editor opens (`testDeck_toolbarButtons`) |
| 3 | PASS | `009a-deck/deck-search-{light,dark}.png` ("ser" → serendipity only), `deck-search-cleared-*.png` (clear button → 3 rows). Spec example "bon" matches no mock card; "ser" used |
| 4 | PASS | `009a-deck/deck-no-matches-{light,dark,forest-light}.png`: magnifier, "No Results for “zzz”", "Check the spelling or try a new search." |
| 5 | PASS | `009a-deck/deck-empty-{light,dark,forest-light}.png` (`rectangle.stack`), `deck-offline-{light,dark,forest-light}.png` (`wifi.slash`); not set up / token rejected in SetupUITests (full suite) |
| 6 | PASS | `009a-deck/deck-context-menu-{light,dark}.png`: Edit (pencil) / Delete (trash, red); ids `deck.row.<id>.edit` / `.contextDelete`; Edit opens "Edit card" prefilled, Delete removes the row |
| 7 | not UI | unit + review (outside QA scope) |
| 8 | **FAIL** | `009a-deck/deck-search-focused-light.png`: the search cursor is **black (ink), not `Theme.accent`** (no accent pixel inside the field). Toolbar, rows, swipe red un-pinked (PASS). The system dismiss button (iOS 27 shows an "X" glass circle, not "Cancel") stays ink, so no second pink element |
| 9 | PASS (with a note) | `009a-deck/deck-ax5-light.png`, `deck-empty-ax5-light.png`, `deck-context-menu-ax5-light.png`: title, toolbar, search, rows and empty state inside the window, no overlap, all ids present. Front/back truncate to one line with an ellipsis, as designed in 002 |

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark + forest
- [x] no default blue tint (keyboard's blue Search key is the system keyboard)
- [x] toolbar buttons aligned (system glass capsule; 009a replaces the custom 44pt circles)
- [x] long text: rows are one line by design; no clipping
- [x] Dynamic Type AX5: no layout break
- [ ] pink accent: expected exactly once on the focused search screen (the cursor); seen zero times

Notes (not blocking):
- At AX5 the meta line truncates the due date: "Due in 3…" (`deck-ax5-light.png`), so the date is lost at the largest
  sizes. Not clipping, but worth a design decision (let the meta line wrap at accessibility sizes?).
- The four ContentUnavailableViews have no description line (spec #5 shows `description: { … }` but gives no text);
  next to the system no-matches view (which has one) they look bare. Design call for design-lead.
- While searching, iOS hides the title and toolbar; dismissing is the system "X" button. Native, fine.

## Bugs
1. **#8 search cursor is not pink.** Open the deck (mock) → tap the search field → type "ser". Expected: the text cursor
   (and selection) in `Theme.accent` (#B8325A light, #ED6E8C dark/forest). Actual: the cursor is ink/black
   (`qa/screenshots/009a-deck/deck-search-focused-light.png`; `testDeck_searchAccentOnly` fails with "no pink inside
   (16.0, 78.0, 315.0, 44.0)"). The `.tint(Theme.accent)` placed after `.searchable` doesn't reach the system search
   field's cursor on iOS 27. Re-run: `scripts/ios-ui-test.sh x -only-testing:LaCarteUITests/DeckUITests/testDeck_searchAccentOnly`.


## Not yet verified (run after the fix / merge)
- Updated queries in Refresh, Settings, Setup, Study and Theme suites (`deckTitle` / `deckSearch`, new Settings gear and
  Theme deck-colour checks) compile but were not run. Run them with the re-test of bug 1.
- `testDeck_addFromStudyThenDelete_liveAPI` (e2e) was updated but not run.

## Re-check 009a-recheck (commit de44440 + main)
Run: `scripts/ios-ui-test.sh --split 3 009a-recheck -only-testing:LaCarteUITests/DeckUITests` -> 28 passed, 0 failed, 1 skipped. No flake recurred.
- #8 PASS: pink (accent) caret visible in `deck-search-focused-light.png` and `deck-search-dark.png`; `deck-search-focused-dark.png` was captured in the caret blink-off phase (not a defect). Only the caret is accent on the search screen; the keyboard Search key is system blue (not app-controlled).
- Global effect: `UISearchTextField.appearance().tintColor` also tints search fields elsewhere (accent caret/selection). Acceptable: spec wants the accent as the single tint, consistent with the app.
- Left unrun: full suite and e2e (post-merge regression run).
