# QA triage: CI run 44902392459 (iOS 26) — UI test failures

Date: 2026-11-21 · CI: macos-26, Xcode 26.6 (17F113), "iPhone 17", iOS 26.x · Local: Xcode 27.0, iPhone 17 Pro, iOS 27.0
Evidence: CI `screenshots` artifact + recordings + `gh run view --log`. Copies of the key images are in
`qa/screenshots/ci-ios26/`.
Local iOS 26 reproduction: **not done**. The disk has 4.3 GB free and an iOS 26 simulator runtime is about 8 GB.
Free about 10 GB to reproduce locally.

12 tests failed (the caller listed 11, plus `ThemeUITests.testTheme_forcedSchemesAndBackToSystem`, also
`testTheme_forestEveryScreen`). There are 4 root causes.

## Root cause A: the simulator never goes dark (CI environment, most likely). 6 tests

Tests: `testDeck_openFromStudy` (dark pass), `testSettings_appearancePicker`, `testTheme_backToSystemInOpenSheets`,
`testTheme_forcedSchemesAndBackToSystem`, `testTheme_forestEveryScreen` ("relaunch without -theme" on the dark
pass).

Evidence: in the artifact, **every** `*-dark.png` taken with theme System is light. That includes screens with
no theme logic in play, e.g. `study-front-dark.png` (background 249,250,245 and a black status bar) and
`deck-empty-dark.png`. Forced themes render correctly (`study-forced-dark-light.png` 26,26,26, forest OK). So
`XCUIDevice.shared.appearance = .dark` had no visible effect on the CI iOS 26 simulator. The app sets
`window.overrideUserInterfaceStyle = .unspecified` for System, which cannot pin light by itself.

Category: (c) environment. The "theme stays light after going back to System" failure is a consequence of
this: the device was light the whole time, so it is **not** evidence of an iOS 26 sheet-override bug.

Not fully proven without a dark-mode check on iOS 26. Owners:
- release-engineer: in CI, log `xcrun simctl ui booted appearance` after the UI step and/or set it with
  `xcrun simctl ui <udid> appearance dark` to confirm.
- ios-engineer or user (one minute): on any iOS 26 simulator or device, theme System + system Dark Mode → the app
  must be dark. If it stays light, this becomes a P1 app bug.

## Root cause B: rating buttons' hit area is under 44pt (real app bug). 4 tests

Tests: `StudyUITests.testStudy_accessibilityXL`, `…XLLongText`, `…XLVeryLongTextScrolls`, `…XXXLCapped`.
`study.rate.again` frame is (16.7, 782.2, w, **39.7**).

Evidence: the glyphs are drawn at the same place on iOS 26 and 27 (ink y 790–819 vs 789–818, measured on
`study-xl-light.png`). Only the button's frame differs. The rating label is
`Text(...).frame(minHeight: 44)` inside a `.plain` button **without `.contentShape`**. A plain button only
hit-tests drawn content, so the transparent padding up to 44pt is not guaranteed to be tappable. iOS 26 reports
the tight frame. iOS 27 happens to report the padded one.

Corroboration on iOS 27: spec 008's new `study.openSettings` / `deck.openSettings` (same `.plain` text button
pattern) report a 24.3pt frame locally (`qa/reports/008-setup.md`).

Category: (a) real. Owner: ios-engineer. `StudyView.ratingLabel` (and `study.reveal`, same pattern) needs
`.frame(minHeight: 44).contentShape(.rect)` so the whole 44pt band is the button. The test stays as is (the 44pt
frame is the spec contract).

## Root cause C: Settings title not vertically centred on the close button (real, visual). 1 test

Test: `SettingsUITests.testSettings_openFromDeckAndClose:30`: title midY 112.8, close midY 118.

Evidence: `qa/screenshots/ci-ios26/settings-header-crop.png`. On iOS 26 "Settings" sits about 5pt above the
centre of the ✕ circle. Ink of the title is y 102–127 on iOS 26 vs 107–132 on iOS 27, with the close glyph at
112–124 in both. `SettingsView.header` uses `HStack(alignment: .top)`, while the deck header ("Cards", which
passes) uses the default centre alignment. On iOS 26 the title's line box is shorter, so top alignment shows.

Category: (a) real, minor. Owner: ios-engineer. Centre the header the same way as the deck header, or use
`.firstTextBaseline` / centre with the XL case kept.

## Root cause D: search (one real bug, one test timing issue)

### D1 `testDeck_search:94`: rows [1,3] with an empty field (real app bug)
Recording (`qa/screenshots/ci-ios26/deck-search-sequence.png`, `deck-search-stale-frames.png`): "ser" → only
serendipity. Then 3 backspaces → the field is **empty**, but the list shows serendipity + ephemeral for more
than 10s. That is exactly the result for query **"s"** ("ephemeral"'s back "lasting a very short time"
contains s; "la carte" contains no s). Every query change cancels the previous load (`CancelID.load`,
`cancelInFlight`), so the store's `query` must have ended on "s": the final change to "" never reached the
store (TextField ↔ store binding lost the last edit). The list then disagrees with the visible field until the
user types again.

Category: (a) real on iOS 26 (rapid deletes; a slow runner makes it more likely). Owner: ios-engineer.
Reproduce on iOS 26: Deck → type "ser" → delete 3 chars quickly → expect all 3 rows. Check the binding path
`TextField(text: $store.query)` → `.binding(\.query)` and add a TestStore test for "ser" → "" that ends with
an empty-query load.

### D2 `testDeck_searchDebounced:117`: got ["se"] (c) CI timing, test fixed
On a slow runner the gap between the "e" and "r" keystrokes was over 0.3s, so a "se" query was correctly sent.
Its result (serendipity) already matched, so the test asserted before "ser" left. Fixed in
`ios/LaCarteUITests/DeckUITests.swift`: the test waits for the "ser" query. If typing took under 0.3s it still
requires exactly ["ser"]. Otherwise it accepts at most one query per prefix of "ser". The "first 'ser' at least
0.3s after typing" check is unchanged.

## Other changes in this pass (ios/LaCarteUITests, scripts/e2e.sh)
- English only: the French seed and fixture words are replaced, with the same semantics. bonjour → greeting,
  merci → gratitude, chien → canine, chat → feline, merle → raven, glissé → slid, un/deux/reste → one/two/stays.
  The Refresh query "ch" became "ine": it matches canine + feline, not raven.
- Spec 008 #14: `APIMode.live` sends `LA_CARTE_API_TOKEN` or `"ui-test-token"`.
- Design-system gallery tests: they now scroll the buttons into view (the new LOGO section pushed them off
  screen). Test-side only.
- Local check (iOS 27): `DeckUITests` searchDebounced + rowsFromAPI and all of `RefreshUITests` pass
  (`qa/screenshots/ci26-triage-mock/`).

## Summary
| Failure | Category | Fix / owner |
|---|---|---|
| Deck openFromStudy (dark), Theme appearancePicker / backToSystemInOpenSheets / forcedSchemes / forestEveryScreen | (c) CI sim ignores `XCUIDevice.appearance` (unconfirmed) | release-engineer: confirm/set with `simctl ui`; ios-engineer: 1-min iOS 26 dark check |
| Study XL ×4: rate hit area 39.7pt | (a) real | ios-engineer: `.contentShape(.rect)` after the 44pt frame |
| Settings title/close not aligned | (a) real, visual | ios-engineer: centre-align the header |
| Deck search: stale "s" results with an empty field | (a) real | ios-engineer: binding loses last edit; TestStore + iOS 26 repro |
| Deck searchDebounced ["se"] | (c) timing | QA: fixed in test |
