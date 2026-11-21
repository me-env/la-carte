# 009a — Native polish: Deck sheet

Status: ready
Owners: ios-engineer
Split from: 009 (native polish, design-lead draft; criteria #6, #7 deck part, #8 deck part, #12, #14 deck part).
Source: `docs/design/native-audit.md` (P1 deck header, deck search, messages, haptics; P2 context menu).
Design reference: docs/design/reference/04-list-dark.jpg (Vyst notes list), plus Apple Notes / Reminders search.

**Parallelism.** Touches only `DeckFeature/DeckView.swift`, `DeckFeature/DeckFeature.swift` and
`DeckFeatureTests`. Safe to run now, next to 007 (widget), 010/011 (Study) and 009b (Editor + Settings).
QA: `DeckUITests.swift` only.

## Goal
The deck sheet behaves like a system list: a large title that collapses, glass toolbar buttons, system search
with a clear button and Cancel, standard empty states, a long-press menu, and a light tap on delete.

## Acceptance criteria
Mock deck = `LA_CARTE_API=mock`.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | The deck sheet is a `NavigationStack` with a large navigation title "Cards" (QA: `app.navigationBars["Cards"]`); it collapses to inline when the list scrolls. The custom title row is gone | UI (light, dark, forest) |
| 2 | Toolbar (`.primaryAction`): settings `gearshape` (`deck.settings`) and add `plus` (`deck.add`), system glass buttons, ink tint; they open Settings and the "New card" editor as today | UI |
| 3 | Search is `.searchable(text: $store.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")`. QA finds it as `app.searchFields.firstMatch`. Typing "bon" shows only matching rows (debounce and reducer unchanged); the clear button empties it and all rows come back. The custom search row is deleted | unit (unchanged) + UI |
| 4 | No matches: `ContentUnavailableView.search(text: query)` | UI |
| 5 | "No cards yet", "Can't reach your deck", "Connect your deck", "Token rejected" use `ContentUnavailableView { Label(title, systemImage:) } description: { … } actions: { … }`. Symbols: `rectangle.stack` (no cards), `wifi.slash` (offline), `link` (not set up), `key` (unauthorized). The title keeps `deck.message`; the "Open Settings" button keeps `deck.openSettings`. They stay inside the scroll view, so pull-to-refresh (006) still works on them | UI (light, dark) |
| 6 | Long-pressing a row shows a context menu "Edit" (`deck.row.<id>.edit`) and "Delete" (destructive, `deck.row.<id>.contextDelete`). Edit opens the editor for that card (`rowTapped`), Delete removes it (`rowSwipedToDelete`) | UI |
| 7 | Haptics: `.impact(weight: .light)` when a row is deleted (swipe or menu); `.error` when a load ends offline or unauthorized. Nothing else in the deck vibrates | unit (trigger state) + review |
| 8 | Accent: the search field's cursor/selection is `Theme.accent` (tint on the search field only, e.g. `.searchable` + `.tint` scoped to it, or the closest iOS 27 equivalent); toolbar buttons, rows and swipe-delete red stay un-pinked | review + UI screenshot |
| 9 | Dynamic Type up to AX5 doesn't clip titles or rows; every interactive element keeps an id | UI (AX5 screenshot) |

## Screens & states
Screenshots (light + dark, forest for `deck`): `deck`, `deck-search` (typed "bon"), `deck-no-matches`,
`deck-empty`, `deck-offline`, `deck-context-menu`, `deck-ax5` (light).

## TCA shape (iOS)
- `DeckFeature.State` gains `var deletions = 0`, incremented in `rowSwipedToDelete` (haptic trigger:
  `.sensoryFeedback(.impact(weight: .light), trigger: store.deletions)`).
- Error haptic: `.sensoryFeedback(.error, trigger: store.phase) { _, new in new == .offline || new == .unauthorized }`.
- No new actions: the context menu sends `rowTapped` / `rowSwipedToDelete`.
- Tests: `deletions` increments on swipe; existing search/delete tests unchanged.

## API / MCP changes
None.

## Accessibility identifiers
New: `deck.row.<id>.edit`, `deck.row.<id>.contextDelete`. Gone: `deck.title` (navigation title), `deck.search`
(system search field: set the id if iOS 27 exposes a way, otherwise QA uses `app.searchFields.firstMatch`).
Unchanged: `deck.settings`, `deck.add`, `deck.message`, `deck.openSettings`, `deck.row.<id>…`.

## Notes for QA
Update `DeckUITests` queries from `staticTexts["deck.title"]` / `textFields["deck.search"]` to the navigation bar and
search field. Long-press with `press(forDuration: 1)`.

## Out of scope
Relative-date localization of the due line (audit P3); pagination (backlog #12); editor/settings sheets (009b).
