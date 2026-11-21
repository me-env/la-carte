# 009b — Native polish: Editor and Settings sheets, launch, glass buttons

Status: ready
Owners: ios-engineer (editor, settings) · design-lead (`CircleIconButton`, `LaunchBackground`, Info.plist)
Split from: 009 (native polish, design-lead draft; criteria #2, #3, #4, #5, #8 editor part, #9, #14 fields part).
Source: `docs/design/native-audit.md` (P1 sheet headers, discard protection; P2 Settings form, launch).
Design reference: docs/design/reference/03-detail-light.jpg (Vyst detail), 05-theme-forest.jpg, Apple Settings / Reminders "New reminder" sheet.

**Parallelism.** ios-engineer touches only `CardEditorFeature/**`, `SettingsFeature/**` and their tests.
design-lead touches only `DesignSystem/CircleIconButton.swift`, `DesignSystemGallery.swift`,
`ios/LaCarte/Assets.xcassets/LaunchBackground.colorset`, `ios/Config/Info.plist`. Safe to run now, next to 007,
010/011 and 009a. (`CircleIconButton` is drawn on Study's top bar, but its API doesn't change, so 010/011 need no
edit.) QA: `SettingsUITests`, `ThemeUITests`, the editor parts of `DeckUITests`/`StudyUITests`, gallery test.

## Goal
Sheets look and behave like iOS: Cancel/Save in the toolbar, no silent loss of typed text, Settings as a `Form`,
no white flash on a dark launch, and round buttons that match the system glass ones.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | **Editor sheet** is a `NavigationStack` with inline title "New card" / "Edit card" (QA: `app.navigationBars`). Toolbar: `Button(role: .confirm)` in `.confirmationAction` (`editor.save`, disabled exactly as today) and `Button(role: .close)` in `.cancellationAction` (`editor.close`). Background `Theme.background` (`.scrollContentBackground(.hidden)`). The old header `HStack` is gone | UI (light, dark, forest) |
| 2 | **Discard protection.** With unsaved changes (front or back differs from the original after trimming), swipe-down does not dismiss (`.interactiveDismissDisabled`), and `editor.close` shows a confirmation dialog "Discard changes?" with "Discard" (destructive, `editor.discard`). On iOS 26+ the system shows it as a popover with Discard only; tapping outside it is "keep editing" (native behaviour, amended after QA 2026-11-21). Discard dismisses; tapping outside leaves text as typed. Without changes, `editor.close` dismisses immediately | unit + UI |
| 3 | Editor: an `.error` haptic plays when a save fails (`saveFailed` becomes true); `editor.error` unchanged | review |
| 4 | **Settings sheet** is a `NavigationStack` + `Form`, inline title "Settings". `Section("Server")`: URL `TextField` (`settings.url`), token field with the reveal toggle from 008 (`settings.token`, `settings.token.reveal`), `Button("Test connection")` (`settings.test`), status line (`settings.status`). `Section("Appearance")`: `Picker` `.segmented` System/Light/Dark/Forest (`settings.theme`; QA selects segments by label). Close = toolbar `Button(role: .close)` (`settings.close`). Form background `Theme.background`, rows `Theme.surface` (`.listRowBackground`), tint ink. `SurfaceRow` is deleted | UI (light, dark, forest) |
| 5 | Choosing "Forest" in the picker switches the theme live, as `themeTapped` does today (picker binds through the existing action) | unit (unchanged) + UI |
| 6 | **Accent**: the editor's front/back fields and Settings' URL/token fields have `.tint(Theme.accent)` on the field only. Toolbar buttons and the segmented picker stay ink | review + UI screenshots |
| 7 | **Launch background** (design-lead): colorset `LaunchBackground` (#F9FAF5 / dark #1A1A1A); `Config/Info.plist` sets `UILaunchScreen.UIColorName = LaunchBackground` (`INFOPLIST_KEY_UILaunchScreen_Generation` stays). No white flash on a dark launch. Build has zero warnings | build + device check |
| 8 | **`CircleIconButton`** (design-lead) renders as `Button` + `.buttonStyle(.glass)` + `.buttonBorderShape(.circle)`, 44 pt, icon in ink; public API and large-content viewer unchanged. Gallery shows it next to a system toolbar button | gallery UI (light, dark, forest) |
| 9 | Dynamic Type up to AX5 doesn't clip either sheet; every interactive element keeps an id | UI (AX5) |

## Screens & states
Screenshots (light + dark, forest where noted): `editor-new` (+ forest), `editor-edit`, `editor-discard`,
`settings` (+ forest), `settings-ax5` (light), `design-system` (gallery, + forest).

## TCA shape (iOS)
- `CardEditorFeature.State`: `var hasChanges: Bool` (computed: trimmed front/back differ from the original card's,
  or from "" for a new card); `@Presents var confirmationDialog: ConfirmationDialogState<Action.Dialog>?`.
- Actions: `closeButtonTapped` → if `hasChanges` set the dialog, else dismiss.
  `confirmationDialog(PresentationAction<Dialog>)` with `Dialog.discardTapped` → dismiss; "Keep editing" is the
  cancel button (dialog just closes).
- View: `.interactiveDismissDisabled(store.hasChanges)`, `.confirmationDialog($store.scope(…))`,
  `.sensoryFeedback(.error, trigger: store.saveFailed) { _, new in new }`.
- `SettingsFeature`: view-only change. The picker uses a `Binding(get: { store.theme }, set: { store.send(.themeTapped($0)) })`.
- Tests: close without changes dismisses; close with changes shows the dialog; discard dismisses; whitespace-only
  change counts as no change.

## API / MCP changes
None.

## Accessibility identifiers
New: `editor.discard`. Gone: `editor.title`, `settings.title` (navigation titles),
`settings.theme.<name>` (segments selected by label). Unchanged: `editor.save`, `editor.close`, `editor.front`,
`editor.back`, `editor.error`, `settings.url`, `settings.token`, `settings.token.reveal`, `settings.test`,
`settings.status`, `settings.close`.

## Out of scope
Deck sheet (009a), Study (009c); any copy change beyond the titles above; app icon (done with 008).
