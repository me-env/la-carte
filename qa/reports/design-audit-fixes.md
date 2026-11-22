# QA: design audit 2026-11-22 fixes

Verdict: PASS
Date: 2026-11-22 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-a64c262f95bd14d51` (67743af + merge of main)
Runs: `qa/screenshots/audit-fix/` (full suite), `qa/screenshots/audit-fix-menu/` (menu in light/dark/forest +
search accent, after QA's test edits), `qa/screenshots/audit-fix-e2e/`
Commands: `UI_WORKERS=3 scripts/ios-ui-test.sh audit-fix` ✅ 83 passed, 0 failed, 10 skipped (live-only) ·
`scripts/ios-ui-test.sh audit-fix-menu -only-testing:…` ✅ 2/2 · `scripts/ios-test.sh` ✅ 225 passed ·
`scripts/e2e.sh audit-fix-e2e` ✅ 10 passed

## Audit items
| Item | Result | Evidence |
|---|---|---|
| P0-1 menu covers the answer | PASS | The menu is now a bottom sheet. Its top edge (y≈1600 px) sits below the answer line (y≈1430 px). The test asserts `study.back.maxY <= first item minY`. `audit-fix-menu/study-report-menu-{light,dark,forest-light}.png` |
| P0-2 one item at a smaller font | PASS | All 6 rows are the same height (the test asserts ≤1 pt spread) and "I want it phrased differently" renders at full size. Same screenshots. |
| P0-3 untokenised greys, nothing dims | PASS | Rows use surface fill, ink text and hairline separators, in two groups (Ask / the reasons). The screen behind is dimmed. The test probes the page at (3, 20%) and asserts its luminance drops after the menu opens (by >20 light, >3 dark/forest). Same screenshots. |
| P0-3b "Other…" alert opens on top | PASS | "What's wrong?" alert shows above the dimmed screen with the keyboard. `audit-fix/study-report-other-light.png`; the full flow passes in `testReport_eachReasonSent`. |
| 010 double tap on text still edits | PASS | `study.backField` opens with the accent cursor and no menu. `audit-fix/study-report-doubletap-text-light.png` |
| P0-4 editor photo breaks the section | PASS | The preview sits in its own bare row. "Photo URL" is a full rounded row. `audit-fix/editor-person-new-light.png`, `editor-person-filled-dark.png` |
| P0-5 Study empty copy | PASS | "No cards yet" (body, ink) / "Ask your agent to add some" (meta, secondaryInk), centered. This matches Deck (`deck-empty-light.png`) and the widget. `audit-fix/study-empty-light.png` |
| P0-6 counter number not pink | PASS | The "3" in "3 to review" is accent and the rest is secondaryInk. `audit-fix/study-front-light.png`, `study-revealed-forest-dark.png`, `study-forest-light.png`. While editing, the counter is hidden, so only the cursor is pink. |
| P0-7 context-menu preview plate | PASS | The lifted row is its own radius-12 card, with no outer white plate. `audit-fix/deck-context-menu-light.png` |
| P0-8 `fieldChanged` after dismiss | PASS* | No TCA "Complete Issue Description" attachment in `audit-fix` or `audit-fix-e2e`. Before the fix, regression-1/2/e2e had one. *Xcode still lists an unreadable "Multiple Runtime Warnings" node on `NotesUITests/testNoteEditor_personCreateEditDelete` (see Tooling request). |
| P1-1 glass circle buttons | PASS | Study's deck, add and retry buttons are glass circles with 17 pt glyphs, matching the editor's xmark and Deck's toolbar glass, in light, dark and forest. `study-front-light.png`, `study-revealed-forest-dark.png`, `study-offline-light.png` |
| P1-4 dot ring over text | PASS | The ring is now drawn under the text: a zoom on "som•ething" shows the grey glyph stem over the dot. `study-swipe-easy-light.png`, `study-swipe-again-forest-dark.png` |
| P1-3 empty/error copy | PASS | Deck and Study use the same title and detail for empty ("No cards yet / Ask your agent to add some"), not set up ("Connect your deck / Add your server URL and token in Settings.") and offline ("Can't reach your deck"). `deck-*-light.png` vs `study-*-light.png` |

Forest coverage: menu, counter, glass buttons and ring are covered in forest. The editor person screen and the
context menu were captured in light/dark only. They are the same native Form and context-menu code paths as their
forest-covered siblings (`editor-new-forest-light.png`).

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark + forest
- [x] nothing competes with the centered text, no default blue tint (the keyboard's blue return key is system, P2-5)
- [x] circle buttons aligned, 44 pt
- [x] long text wraps, no truncation
- [ ] Dynamic Type XL: deferred (accessibility checks deferred)

## Design notes (not blocking, for design-lead)
1. Dot ring: the dots no longer cover the glyphs, but a black dot still sits inside "m" and "o" of the answer. A
   background-coloured halo around the text (the audit's alternative) would separate them fully.
2. P1-3 visual pattern: the copy now matches, but Deck still uses `ContentUnavailableView` (symbol + bold title)
   while Study uses plain text. Deck's offline state still has no retry, which the audit suggested.
3. Report sheet: ~50 pt of empty sheet below "Other…" (`study-report-menu-light.png`).

## Test edits review (engineer's 5 files)
- `StudyUITests`: the new `assertEmptyDeck` checks the copy, centering, order and the absence of the other ids. Sound.
- `RatingsUITests`, `RefreshUITests`: "All caught up" became "No cards yet" because those stubs end on (or start
  with) an empty deck. That is correct under the new P0-5 copy, and what each test was checking is kept.
- `ReportUITests`: adds equal-height and below-answer checks, and `cancelMenu` taps the dimmed area. Sound.
  QA added a dim check and a forest pass.
- `ThemeUITests`: dropped the `study.deck` surface-fill pixel probe because the button is now system glass (not a
  token colour). That is acceptable: the background probes are kept, and the button is checked on screenshots.

QA also fixed the CI flake in `DeckUITests/testDeck_searchAccentOnly`. The test now captures frames back to back over
1.2 s, passes if any frame shows the accent inside the search field, and checks that frame for accent anywhere else.

## Bugs
None.

Tooling request: `xcresulttool` shows only the name "Multiple Runtime Warnings" for runtime-warning nodes, not their
text. QA can't tell a TCA warning from a SwiftUI one. `ios-ui-test.sh` could export runtime-warning messages per
test into the screenshot folder.
