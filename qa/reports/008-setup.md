# QA: 008 Setup: "Connect your deck" and "Token rejected"

Verdict: **PASS** (round 4; #15 is still a user device check)
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27.0
Runs: `qa/screenshots/008-r4/` (full mock suite), `qa/screenshots/008-r4-setup/` (SettingsUITests only, first pass),
`qa/screenshots/008-e2e-r2/` (live API). Earlier rounds: `008-mock`, `008-mock-r2`, `008-mock-r3`, `008-e2e`.
Commands:
- `scripts/ios-ui-test.sh 008-r4` (full suite): **PASS**. 69 passed, 0 failed, 6 `_liveAPI` skipped.
- `scripts/e2e.sh 008-e2e-r2`: **PASS**, 6/6.

Test changes this round (`ios/LaCarteUITests`):
- New `SettingsUITests.testSetup_tokenMasked` (#16, light / dark / forest, fake token `fake-qa-token-0000`).
  It checks: a tap on the row reveals and focuses the field; typed text shows in plain text; moving focus to the URL
  field masks it again (one dot per character, label "Token", the token appears in no label or value); the eye
  (`settings.token.reveal`, 44x44pt, "Show token" / "Hide token") reveals and hides; a tap on the row away from the
  dots (near its top edge) reveals and focuses; and closing Settings shows no prompt.
- `dismissSavePasswordPrompt` is replaced by `assertNoSavePasswordPrompt`, which runs after every
  `closeSettingsSheet` and after the swipe in `_connectFromStudy`. It fails if "Not Now" or "Save Password…" shows
  within 2s.
- The `.secureTextField` type checks are gone. The token is checked through its value: "" or dots at rest, and
  dots of the right length after a relaunch (`testSettings_persistAcrossRelaunch`, plus `assertTokenNotOnScreen`).
- The 44pt hit-area checks now use `>= 43.99` (fractional origins): `study.openSettings`, `deck.openSettings`,
  `study.rate.*`, and the new `study.reveal` check in `testStudy_frontRevealRateNext`.
- Settings token row height is now measured as the token text plus the eye button. The masked token's own
  accessibility frame is only the text, 24pt tall. The row is a 44pt tap target, which the off-text tap in
  `_tokenMasked` proves. The colour check samples the row fill at the URL row's right edge.
- The Settings header check is tightened: the title's midY must be within 1.5pt of the close button's (was 4pt).

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS (review part) | no `127.0.0.1` default in `ios/LaCarteKit/Sources` / `ios/LaCarte` (round 1). Unit part is the engineer's |
| 2 | PASS (UI side) | `.mock` suites are set up, `.stored` tests are not set up until both values are typed. Truth table is unit |
| 3 | not UI-tested | unit |
| 4 | PASS | `008-r4/study-not-set-up-{light,dark,forest-light}.png`: copy, centred layout, no remaining / retry, top bar kept. `study.openSettings` >= 44pt |
| 5 | PASS | `008-r4/settings-from-study-light.png`: Settings directly over Study (no deck behind), placeholders shown |
| 6 | PASS | `testSetup_connectFromStudy`: URL only → close → still "Connect your deck", 0 requests. Add token → swipe → no prompt → "alpha", "2 to review" (`008-r4/study-after-setup-light.png`) |
| 7 | not UI-tested | unit |
| 8 | PASS | `008-r4/study-token-rejected-{light,dark,forest-light}.png`: copy OK, `Bearer wrong` sent, no retry, button >= 44pt |
| 9 | PASS | the offline tests pass in the full suite |
| 10 | not UI-tested | unit |
| 11 | PASS | `008-r4/deck-not-set-up-{light,dark}.png`, `deck-token-rejected-light.png`, `deck-offline-after-setup-light.png` (no button). `deck.openSettings` >= 44pt and opens the deck's Settings |
| 12 | PASS | `testSetup_clearTokenFromDeck`: clear token → deck "Connect your deck" → close deck → Study "Connect your deck" |
| 13 | PASS | placeholders "Server URL" / "Token" (`settings-from-study-light.png`). 401 → "Wrong token" (`testSettings_wrongToken`). 403 is unit |
| 14 | PASS | full mock suite 69/69 green (6 live skipped), e2e 6/6 |
| 15 | **pending** | user device check after a clean Ad Hoc install |
| 16 | PASS | `008-r4/settings-token-masked-{light,dark,forest-light}.png` (dots, eye; no token text), `settings-token-revealed-{light,dark,forest-light}.png` (plain text, `eye.slash`). Masks again on focus loss. No "Save Password?" in any `testSetup_*` / `testSettings_*` close (asserted). Saved token shows masked on reopen and after a relaunch. `.privacySensitive()` is not observable in UI tests (unit / review) |

## Earlier iOS 26 triage items, re-checked on iOS 27 locally
- Rating hit area at XL (root cause B): `testStudy_accessibilityXL`, `…XLLongText`, `…XLVeryLongTextScrolls`,
  `…XXXLCapped` pass with `study.rate.*` >= 43.99pt (`008-r4/study-xl-light.png`).
- Settings header (root cause C): the title is centred on the close button within 1.5pt in every Settings test
  (`008-r4/settings-light.png`, `settings-xl-light.png`).
- iOS 26.5 re-run: see the next section.

## iOS 26.5 re-run (`qa/screenshots/ios26-r1/`)
Run: `SIMULATOR="iPhone 17 Pro" OS=26.5 scripts/ios-ui-test.sh ios26-r1 -only-testing:…`. CI's "iPhone 17" has
no 26.5 runtime locally. The 17 Pro has the same 402pt width.
- `testDeck_search`, `testDeck_searchDebounced`: **PASS**. The "deleted query never reaches the store" bug does
  **not** reproduce on 26.5 locally, so there is no repro to give. It stays CI-only (Xcode 26.6 / the runner's
  26.x build).
- `testStudy_accessibilityXL`, `…XLLongText`, `…XLVeryLongTextScrolls`, `…XXXLCapped`: **PASS**. The rating hit
  area is fixed on 26.5 too.
- `testSettings_openFromDeckAndClose`: header / layout asserts pass, so the title is centred. The test **FAILS**
  only on the dark colour check ("sheet background … is (249,250,245), expected (26,26,26)").
- `testDeck_openFromStudy` (dark pass), `testTheme_forcedSchemesAndBackToSystem`, `…backToSystemInOpenSheets`,
  `…forestEveryScreen`: **FAIL**. Every System-theme "dark" screen renders light. `deck-search-dark.png` shows a
  light keyboard and black status-bar text. Forced themes render correctly. This is the same signature as CI root
  cause A: an xcodebuild-booted simulator ignores `XCUIDevice.shared.appearance`. It is most likely environmental,
  not the app: the same code passes on iOS 27. I can't confirm it without `ci/boot-simulator.sh`, which uses
  `simctl ui`, and QA doesn't run that unattended. To confirm: run
  `SIMULATOR="iPhone 17 Pro" OS=26.5 ci/boot-simulator.sh`, then rerun the four Theme/Deck tests. If they still
  render light, it's a P1 app bug (System theme ignores system Dark Mode on iOS 26).

## Visual review
- [x] background edge to edge in light, dark and forest. Message in ink, detail in `.meta` secondary, quiet "Open
  Settings" text button, no tint.
- [x] circle buttons aligned. The top bar is kept in both states.
- [x] 44pt hit areas: `study.openSettings`, `deck.openSettings`, `study.reveal`, `study.rate.*`, `settings.token.reveal`,
  and the token row.
- [x] nothing covers the result: no "Save Password?" sheet.
- [x] token row: the dots sit on the URL text's leading edge (about 1pt off, from the bullet glyph's side bearing,
  not visible at 1x). The eye is secondary ink. The row fill matches the URL row in all three themes.
- Note (not a bug): when the token is revealed, the keyboard shows an empty QuickType bar (`settings-token-revealed-*.png`).
  The URL field doesn't. It's harmless.

## Bugs
None open for 008.
