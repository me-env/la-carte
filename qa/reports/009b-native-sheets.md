# QA: 009b Native sheets (editor + Settings)

Verdict: **FAIL** (1 spec deviation: no "Keep editing" button, see bug 1. Everything else passes)
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27 (UI pool, `--split 3`)
Branch: `worktree-agent-a881f7f2f369745f3` (commit `addabbe`), worktree `.claude/worktrees/agent-a881f7f2f369745f3`
Runs: `qa/screenshots/009b-mock/` (feature classes + smoke, first pass), `009b-mock-r2/` (re-run of the 13 failures
after test updates), `009b-mock-r3/`, `009b-setup/` (spec 008 Setup tests), `009b-e2e/`
Commands:
- `scripts/ios-ui-test.sh --split 3 009b-mock` with SettingsUITests, ThemeUITests, DeckUITests and the CI smoke set:
  35 passed, 13 failed. All 13 were test-side (old ids, 44pt checks on system controls, old layout) or the dark-mode
  flake below. They pass after the test updates: `009b-mock-r2` 12/13, then `009b-mock-r3` 1/1 ✅
- `scripts/e2e.sh 009b-e2e`: 6/6 ✅
- `scripts/ios-ui-test.sh 009b-setup` (5 Setup tests, not split: `--split` misses them, see Tooling): 5/5 ✅
- Full regression suite: not run, per the manager's rule (runs once after the merge)

Scope: the brief covers the editor and Settings only. #7 (LaunchBackground) and #8 (glass `CircleIconButton`) are
design-lead's work and are on neither this branch nor `main`, so they were **not validated**.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | Native `NavigationStack`, inline "New card"/"Edit card" (`app.navigationBars`), `editor.close` in the leading slot, `editor.save` (confirm ✓) in the trailing slot, Save disabled when empty, `editor.title` gone. Background `Theme.background`, rows `surface`. `009b-mock-r2/editor-new-{light,dark}.png`, `editor-edit-{light,dark}.png`, `editor-new-forest-{light,dark}.png`, `editor-forest-*.png`; `assertEditorChrome`, `assertEditorColors` |
| 2 | **FAIL (bug 1)** | Swipe-down blocked with changes ✅. `editor.close` with changes shows "Discard changes?" with **Discard** (destructive, `editor.discard` reachable **by id**) ✅. Discard dismisses ✅. No change, whitespace-only change, or an edit typed back to the original: close or swipe dismisses at once ✅. But there is **no "Keep editing" button** (`editor.keepEditing` / label absent). Tapping outside the popover keeps the text ✅. `009b-mock-r2/editor-discard-{light,dark}.png`, `009b-mock/editor-discard-ax5-light.png`; `testEditor_discardProtection`, `testEditor_closeWithoutSaving` |
| 3 | PASS (review) | `CardEditorView`: `.sensoryFeedback(.error, trigger: store.saveFailed) { _, new in new }`. `editor.error` unchanged (`editor-error-*.png`, `testEditor_saveFailureKeepsText`) |
| 4 | PASS | `NavigationStack` + `Form`, inline "Settings", sections Server (URL, masked token + eye, Test connection, status) and Appearance (segmented System/Light/Dark/Forest, picked by label). `settings.close` is a toolbar close, `settings.title`/`settings.theme.<name>` are gone. Background/rows/ink checked by pixel in light, dark and forest. `009b-mock/settings-forest-{light,dark}.png`, `009b-mock-r2/settings-appearance-{light,dark}.png`, `deck-with-settings-light.png` |
| 5 | PASS | Tapping Forest/Dark/Light re-themes the open sheet, the deck under it and study at once. `009b-mock/settings-switched-*.png`, `study-switched-forest-light.png`; `testTheme_switchLiveAcrossSheets`, `testTheme_backToSystemInOpenSheets` (r2) |
| 6 | PASS | The only pink on any screen is the caret of the focused field (`editor-new-forest-light.png`, `editor-discard-dark.png`). Toolbar buttons are ink/system glass, the segmented picker is system grey, no default blue. The red "Discard" is system red (hue 359°, accent is 346°) |
| 7 | NOT VALIDATED | design-lead lane, not implemented on this branch or `main` (no `LaunchBackground.colorset`) |
| 8 | NOT VALIDATED | design-lead lane, `CircleIconButton` is not glass yet. Gallery tests not run here |
| 9 | PASS | AX5 (`UICTContentSizeCategoryAccessibilityXXXL`): editor new/edit/discard and Settings don't clip. Every id exists, sits inside the window and doesn't overlap the others, and the theme segments are hittable. `009b-mock/editor-new-ax5-light.png`, `editor-edit-ax5-light.png`, `editor-discard-ax5-light.png`, `settings-ax5-light.png`, `settings-ax5-scrolled-light.png`. Minor note 2 below |

### Spec 008 #16 re-verified on the new Form
Token masked at rest (one dot per character, never in clear), eye `settings.token.reveal` toggles, tapping the row
reveals and focuses, focus moving away masks it again, and no "Save Password?" after closing:
`testSetup_tokenMasked`, `testSetup_connectFromStudy` (`assertNoSavePasswordPrompt`), `testSettings_persistAcrossRelaunch`.
Result: **PASS**, 5/5 Setup tests (`009b-setup/settings-token-masked-*.png`, `settings-token-revealed-{light,dark,forest-light}.png`, `study-token-rejected-*.png`)

## Visual review (docs/design-system.md checklist)
- [x] Background edge to edge in light, dark and forest (Form `scrollContentBackground(.hidden)`, pixel checks pass)
- [x] Nothing competes and there is no default blue tint. Pink only on the focused field's caret (at most one accent element)
- [x] Circle buttons: native toolbar glass buttons, frame 36pt (system hit area). Checks relaxed to "system toolbar button"
- [x] No truncation. Long backs wrap at AX5 (`editor-edit-ax5-light.png`)
- [x] Dynamic Type XL and AX5 OK (see note 2)

## Bugs
1. **No "Keep editing" button in the discard dialog (#2).** Steps: Deck → + → type "feline" → tap close (X).
   Expected (spec #2): a dialog with "Discard" (`editor.discard`) and "Keep editing" (`editor.keepEditing`).
   Actual: on iOS 26+ `confirmationDialog` shows as a popover from the toolbar with only "Discard". The `.cancel`
   button is hidden, and you keep editing by tapping outside it (`009b-mock-r2/editor-discard-dark.png`).
   `editor.keepEditing` is unreachable. Needs a decision. Either the **architect** amends #2 to "tap outside the
   dialog = Keep editing" (native iOS 26 behaviour, no code change; the test already handles both), or the
   **ios-engineer** presents it so a visible "Keep editing" exists (e.g. an `.alert` with Discard/Keep editing).

Non-blocking notes:
2. AX5: the eye glyph in the token row grows beyond its fixed 44×44 frame, nearly to the row edge
   (`settings-ax5-light.png`). Not clipped, but the visible glyph is larger than its hit area.
   Suggested fix (ios-engineer): `.frame(minWidth: 44, minHeight: 44)` instead of a fixed frame.
3. Segmented picker labels don't scale with Dynamic Type (a system control). They stay readable and unclipped.
4. Flake, not app: on the first pass, `testTheme_backToSystemInOpenSheets` (dark device) and
   `testTheme_forestEveryScreen` ("relaunch without -theme", dark) saw a light app on one pool simulator.
   The same tests passed on the re-run (`009b-mock-r2`). Same symptom as `ci-ios26-triage.md` root cause A
   (`XCUIDevice.appearance` not applied).

## Test changes (ios/LaCarteUITests)
- Support: `sheetBar`/`editorBar`/`sheetTitle`/`waitForSheet` (titles come from `app.navigationBars`), `themeSegment`
  (segments by label), `accessibilityAX5Arguments`.
- Settings/Setup/Theme/Deck/Study: `editor.title`/`settings.title`/`settings.theme.*` replaced. The chrome checks now
  match the native layout (close leading, save trailing, centred inline title). The custom ink/surface pixel checks on
  system controls (glass close, segments) were dropped. Toolbar buttons are checked at ≥ 36pt (system).
- New: `testEditor_discardProtection` (light + dark), `testEditor_accessibilityAX5`, `testSettings_accessibilityAX5`.
  `testEditor_closeWithoutSaving` now confirms Discard.

## Tooling
- `ios-ui-test.sh --split` finds tests by grepping `func test` per class file, so it **skips test methods declared in
  an extension in another file** (`SetupUITests.swift` extends `SettingsUITests`): `-only-testing:…/SettingsUITests`
  ran 0 Setup tests, and explicit `…/SettingsUITests/testSetup_*` filters fail with "No UI test matches".
- This branch predates the `--split`/pool scripts. QA ran `main`'s `scripts/` in the worktree (not committed).
