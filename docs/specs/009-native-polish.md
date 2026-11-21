# 009 — Native polish: system chrome, states, haptics, icon

Status: split — implement from [009a](009a-native-deck.md) (Deck), [009b](009b-native-sheets.md) (Editor, Settings, launch, glass buttons), [009c](009c-native-study.md) (Study, after 011). This file stays as the design-lead source; #1 (app icon) is done.
Owners: ios-engineer (features), design-lead (DesignSystem, AppIcon, LaunchBackground)
Depends on: 006 (refresh) and 008 (setup) merged first, because both edit the same views. Independent of 007,
except the `CircleIconButton` change (#9), which the widget doesn't use.
Source: `docs/design/native-audit.md` (P0–P2 items). Design reference: docs/design/reference/01–05.

## Goal
The app feels like Apple built it: system toolbars, search, empty states, forms, haptics and a real app icon.
The calm Vyst feel stays (paper background, one thing centered, ink tint). No new features, and no visual noise.

## User stories
- As the user, I see a la-carte icon on my Home Screen, not a blank one.
- As the user, sheets and search behave like every other iOS app (Cancel, clear button, swipe protection).
- As the user, I feel a light tap when I reveal and rate a card.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | **App icon.** **Done (landed with the 008 build).** Not set today: `xcodebuild -showBuildSettings` shows no `ASSETCATALOG_COMPILER_APPICON_NAME`, and neither the project nor `Config/*.xcconfig` sets it, so `AppIcon.appiconset` is compiled but never used. Change: in `ios/LaCarte.xcodeproj/project.pbxproj`, add the line `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;` right above `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;` in **both** `buildSettings` blocks of the LaCarte target (Debug `…111000000` and Release `…112000000`). Don't put it at project level, or the UI-test target would inherit it. The fanned-cards icon (light/dark/tinted 1024, from `docs/design/brand/render.sh`) then ships. Build has zero warnings | build + device check |
| 2 | **Launch background.** New colorset `LaunchBackground` (#F9FAF5 / dark #1A1A1A). `INFOPLIST_KEY_UILaunchScreen_Generation` stays, with `UILaunchScreen.UIColorName = LaunchBackground` in `Config/Info.plist`. No white flash on dark launch | device check |
| 3 | **Editor sheet.** In a `NavigationStack`: `.navigationTitle("New card"/"Edit card")` (inline), `.toolbar`: `Button(role: .confirm)` in `.confirmationAction` (id `editor.save`, disabled as today) and `Button(role: .close)` in `.cancellationAction` (id `editor.close`). `.scrollContentBackground(.hidden)` + `Theme.background`. The old header `HStack` is gone, and `editor.title` moves to the navigation title (QA queries `app.navigationBars`) | UI (light, dark, forest) |
| 4 | **Editor discard protection.** With unsaved changes, swipe-down is blocked (`.interactiveDismissDisabled`), and close shows `confirmationDialog` "Discard changes?" with "Discard" (destructive, `editor.discard`) and "Keep editing". Without changes, close dismisses immediately | unit + UI |
| 5 | **Settings sheet.** `NavigationStack` + `Form`: `Section("Server")` with `TextField` (`settings.url`), `SecureField` (`settings.token`), `Button("Test connection")` (`settings.test`) and the status line (`settings.status`). `Section("Appearance")`: `Picker` `.segmented` with System/Light/Dark/Forest (`settings.theme`; segments keep `settings.theme.<name>` if the picker exposes them, otherwise QA selects by label). Close = toolbar `Button(role: .close)` (`settings.close`). Form background = `Theme.background`, rows = `Theme.surface` (`.listRowBackground`), tint = ink. `SurfaceRow` is deleted | UI (light, dark, forest) |
| 6 | **Deck sheet.** `NavigationStack`, `.navigationTitle("Cards")` large (`deck.title` → navigation bar). Toolbar: settings (`gearshape`, `deck.settings`) and add (`plus`, `deck.add`) in `.primaryAction`. Search uses `.searchable(text: $store.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")`, and QA queries `app.searchFields` (`deck.search` id is set via `.searchable`'s field where possible). Debounce and reducer unchanged. The custom search row is deleted | unit (unchanged) + UI |
| 7 | **Message states → `ContentUnavailableView`.** Deck: "No matches" = `ContentUnavailableView.search(text:)`. "No cards yet", "Can't reach your deck", "Connect your deck", "Token rejected" use `ContentUnavailableView` (label + description + action where 008 has one). Study: offline / not set up / token rejected use the same, with the retry action as a text button. Ids stay on the inner title (`*.message`), description (`*.detail`) and buttons. All stay inside the pull-to-refresh scroll view (006). Study's **caught-up** stays custom (card-face type, the brand moment) | UI (light, dark) |
| 8 | **Haptics** (`.sensoryFeedback`): `.selection` on reveal, `.success` after a rating is sent, `.impact(weight: .light)` on swipe-delete, `.error` when a load or save fails. Nothing else vibrates | review + device check |
| 9 | **`CircleIconButton`** (design-lead, DesignSystem) renders as `Button` + `.buttonStyle(.glass)` + `.buttonBorderShape(.circle)`, 44 pt, icon in ink. The API and large-content viewer are unchanged, so it still matches the toolbar buttons from #3–#6 on Study's top bar | gallery UI (light, dark, forest) |
| 10 | **Study counter** `study.remaining` uses `.contentTransition(.numericText(countsDown: true))`, animated with `Theme.Motion.standard` | review |
| 11 | **Study loading** shows `LaCarteLoadingMark` (64 pt, centered) when loading lasts > 0.5 s (id `study.loading`). Reduce Motion gives the opacity pulse (built in) | unit (timer) + UI |
| 12 | **Deck row context menu:** long-press shows "Edit" and "Delete" (destructive). Both send the existing actions | UI |
| 14 | **Accent, very small amounts** (rule in `docs/design-system.md`): text fields in the editor, Settings and deck search get `.tint(Theme.accent)` on the **field only** (cursor + selection pink). The rest of the screen keeps `.tint(Theme.ink)`, and toolbar buttons, the segmented picker and the swipe-delete red stay un-pinked. `study.remaining`'s number is `Theme.accent`, "to review" stays `secondaryInk` (one `Text` concatenation, still `.numericText`). No other pink | review + UI screenshots |
| 13 | Every animation added here has a Reduce Motion variant, Dynamic Type up to AX5 doesn't clip, and every interactive element keeps an id | UI (AX size, Reduce Motion launch arg) |

## Screens & states
Screenshots (light + dark, forest where noted): `editor-new`, `editor-discard`, `settings` (+ forest), `deck`,
`deck-search`, `deck-no-matches`, `deck-context-menu`, `study-offline`, `study-loading`, `design-system` (gallery
incl. logo + glass buttons, + forest).

## TCA shape (iOS)
- No new modules. `CardEditorFeature` gains `@Presents var alert: ConfirmationDialogState<…>` (or
  `confirmationDialog`), plus `hasChanges` (computed). Close with changes → dialog. Confirm → `dismiss`.
- `StudyFeature`: `isLoadingVisible` set by a 0.5 s `clock.sleep` effect, cancelled on load.
- Everything else is view-only.

## API / MCP changes
None.

## Accessibility identifiers
New: `editor.discard`, `study.loading`. Moved: `editor.title`, `settings.title`, `deck.title` (navigation titles),
`deck.search` (search field). All others unchanged.

## Notes for QA
UI tests that find titles/search by `staticTexts["deck.title"]` / `textFields["deck.search"]` need updating to
navigation bars / search fields. Glass rendering differs a little between simulator and device. Judge against
the gallery screenshots.

## Out of scope
- Zoom navigation transition Study → Deck (audit P3), relative-date localization (P3), iPad layout.
- Any copy change beyond what's listed.
