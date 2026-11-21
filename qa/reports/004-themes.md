# QA: 004 Themes (system / light / dark / forest)

Verdict: PASS (round 2)
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27
Runs: `qa/screenshots/004-final/` (full UI suite), `qa/screenshots/004-final-e2e/`
Commands: `scripts/ios-ui-test.sh 004-final` (✅ 56 passed, 0 failed, 5 live tests skipped as designed),
`scripts/e2e.sh 004-final-e2e` (✅ 5/5), full suite (same run as 004-final: specs 000–004 all green, no regressions)

History: round 1 (2026-11-21, runs `004-mock`/`004-e2e`) FAIL, bug 1: open sheets kept the previous forced color scheme
when the theme changed away from Light/Dark. Round 2: fixed, verified on screen (repros A–D below).

Tests: `ios/LaCarteUITests/ThemeUITests.swift` (10 tests). Round 2 added two snapshots for the bug 1 repros:
`settings-switched-system` (repro C, end state) and `settings-reopened-back-to-system-after-<forced>` (repro D).
`Support.swift`: `launch(…, theme:)` passes `-theme system` by default; tests that tap the picker pass `theme: nil` and
register `resetThemeOnTeardown()`. `scripts/e2e.sh` also runs `ThemeUITests/testTheme_forestDeck_liveAPI` (read-only).

Pixel checks use the spec palette: forest background `#0E1913` (14,25,19), surface `#16241B` (22,36,27),
ink `#EEF2EC`, secondaryInk `#83938A`. Light and dark use the design-system values. Tolerance is ±4, or ±8 for text glyphs.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `settings-appearance-{light,dark}.png`. `testSettings_appearancePicker`: "Appearance" sits below the server section, with four 44pt options of equal width in order (System, Light, Dark, Forest) on one row. Only `settings.theme.system` has the selected trait. The selected option is filled with ink and the others with surface (pixel-checked). Default is System: the stored value after the reset, plus `-theme` not passed |
| 2 | PASS | Round 2: bug 1 fixed. Every switch re-themes the open Settings sheet, the Deck sheet under it and Study at once, including Dark→System (`settings-back-to-system-after-dark-light.png`, `deck-back-to-system-after-dark-light.png`), Light→System (`…-after-light-dark.png`), Forest→Dark→Light→System (`settings-switched-{forest,dark,light,system}-light.png`, `deck-switched-*-light.png`) and reopen→System (`settings-reopened-back-to-system-after-{dark-light,light-dark}.png`). |
| 3 | PASS | Device dark + Light: light palette, dark status-bar text, light keyboard (`study-forced-light-dark.png`, `settings-forced-light-keyboard-dark.png`). Device light + Dark: `study-forced-dark-light.png`, `settings-forced-dark-keyboard-light.png`. Device light + Forest: light status-bar text, dark keyboard (`settings-forest-keyboard-light.png`, `editor-new-forest-light.png`). With Light forced, flipping the device changes nothing. With System, a live device flip re-themes Study. Going back to System now re-themes the open sheets too (`settings-reopened-back-to-system-after-light-dark.png`) |
| 4 | PASS | Pixels match `#0E1913`/`#16241B` on Study (front, revealed, caught up), Deck (background, rows, search, circle buttons), Editor, Settings and the gallery, on a light and a dark device. Glyph colors: `study.front` and `study.message` are ink `#EEF2EC`; `study.remaining` and `study.back` are secondaryInk `#83938A`. Light and dark values are unchanged (pixel checks from specs 001–003 still pass). Screens: `study-forest-*`, `study-revealed-forest-*`, `study-caught-up-forest-*`, `deck-forest-*`, `editor-forest-*`, `settings-forest-*`, `design-system-forest-*` |
| 5 | PASS | `testTheme_persistsAcrossRelaunch`: Forest, and Light on a dark device, both survive terminate + relaunch with no argument. Study opens themed (`study-relaunched-forest-light.png`, `study-relaunched-light-dark.png`) and the picker shows the stored option as selected |
| 6 | PASS | `testTheme_forestEveryScreen` / `testDesignSystem_forest`: `-theme forest` starts Study, Deck, Editor, Settings (Forest selected) and the gallery in forest. A plain relaunch afterwards is back on System, so the argument is not written to the stored value. E2E: `004-final-e2e/study-live-forest-light.png`, `deck-live-forest-light.png` (round 2) |
| 7 | n/a (review) | Not UI-validated; left to code review |

Accessibility XL (`testTheme_accessibilityXL`): at AX-XL the options stack vertically, full width, 44pt+, inside the
window, with no overlap and no truncation. Forest can be picked (`settings-appearance-xl-{light,dark}.png`,
`settings-forest-xl-{light,dark}.png`). Forest Study at XL stays readable (`study-forest-xl-*`, `study-revealed-forest-xl-*`).

## Visual review (docs/design-system.md checklist)
- [x] Background edge to edge in light, dark and forest (pixel-checked at corners and edges on every screen)
- [x] Nothing competes with the centered text and there is no default blue tint. Forest accents are ink, not system green or blue
- [x] Circle buttons are 44pt and aligned. In forest the surface fill and hairline border read as in ref 05
- [x] Long text wraps with no truncation in the main area (deck rows are one line by spec 002 design)
- [x] Dynamic Type XL works, picker included
- [x] Sheets follow the theme (round 2): every switch, including back to System, re-themes open sheets

## Bug 1 re-check (round 2), all in `004-final/`
- Repro A (device light, Dark → System, sheets open): Settings and Deck sheets are light, System chip ink-filled black
  (`settings-back-to-system-after-dark-light.png`, `deck-back-to-system-after-dark-light.png`). Fixed.
- Repro B (device dark, Light → System): both sheets dark (`settings-back-to-system-after-light-dark.png`,
  `deck-back-to-system-after-light-dark.png`). Fixed.
- Repro C (device light, Forest → Dark → Light, then System): Settings and Deck light at each step
  (`settings-switched-light-light.png`, `deck-switched-light-light.png`, `settings-switched-system-light.png`). Fixed.
- Repro D (device dark, Light chosen, sheets closed and reopened, → System): Settings dark
  (`settings-reopened-back-to-system-after-light-dark.png`). Fixed.

**Forest compared with `05-theme-forest.jpg`:** close match, unchanged from round 1 (`study-forest-light.png`,
`editor-new-forest-light.png`, `deck-forest-dark.png`, E2E `004-final-e2e/deck-live-forest-light.png`).

**Gallery alignment:** the round 1 note is resolved. The FOREST swatches now start at the same x as the COLORS
swatches. In light/dark they sit in a forest-coloured panel that bleeds into the margin (`design-system-light.png`,
`design-system-dark.png`), and in forest the panel blends in with nothing shifted (`design-system-forest-light.png`).

**Final whole-app regression** (spot-checked light + dark: `study-revealed-light`, `study-front-dark`, `deck-light`,
`editor-new-light`, `editor-edit-dark`, `settings-dark`, `design-system-{light,dark}`, `study-forced-light-dark`):
consistent type scale, margins, 44pt circle chrome and sheet header pattern. No blue tint. No regressions in specs 000–003.
Non-blocking note, unchanged from round 1: in mock runs Settings shows a URL left over from `SettingsUITests` stub
servers (e.g. `http://127.0.0.1:28135`) and an empty token row. This is test-state leakage, not a product issue.

## Bugs
None open. Round 1 bug 1 (open sheets stuck in the previous forced scheme) is fixed and verified.
