# 002 — Deck list + add / edit card

Status: done
Owners: ios-engineer
Depends on: 001 (StudyFeature, App composition)
Design reference: docs/design/reference/04-list-dark.jpg (list), 03-detail-light.jpg (sheet)
Changes (after review/QA): `deleteResponse` carries the deleted id; the swipe "Delete" is the system destructive
red with `deck.row.<id>.delete`; a swipe cancels any deck load in flight so the deleted row can't come back,
and a successful delete reloads with the current query so the list always matches the search field.

## Goal
The user can see every card, search, delete with a swipe, add a card and fix a card's text, from the deck
and (for adding) straight from the study screen. The study screen picks up the changes.
Covers backlog items 3 and 4.

## User stories
- As the user, I open my deck from study and scan my cards: front, a preview of the back, state, when due.
- As the user, I search my deck, swipe a card away to delete it, tap a card to edit it.
- As the user, I add a card from study or from the deck, by typing a front and a back.

## Acceptance criteria
Mock deck = `LA_CARTE_API=mock` (3 fixtures, all due, state new).

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Tapping `study.deck` presents the deck sheet: `deck.title` "Cards" and one `deck.row.<id>` per card, newest first; each row shows `deck.row.<id>.due` ("Due now" or "Due in 3 days"), `deck.row.<id>.state` ("new"), the front (1 line) and the back preview (1 line, `secondaryInk`) | unit + UI (light + dark) |
| 2 | Typing in `deck.search` filters through `GET /cards?query=` after a 0.3s debounce; "ser" leaves only the `serendipity` row; clearing the field shows all cards again | unit (TestClock) + UI |
| 3 | A search with no results, an empty deck, and a failed load show `deck.message` "No matches" / "No cards yet" / "Can't reach your deck" respectively, with no rows | unit + UI ("No matches") |
| 4 | Swiping a row left reveals a destructive "Delete" (`deck.row.<id>.delete`, system red); confirming removes the row immediately, cancels any deck load in flight and calls `DELETE /cards/{id}`; on failure the list is reloaded from the API | unit + UI |
| 5 | Tapping a row presents the editor (`editor.title` "Edit card") prefilled with that card's front and back; changing the back and tapping `editor.save` calls `PATCH /cards/{id}`, dismisses the editor and the row shows the new back | unit + UI |
| 6 | Tapping `deck.add` presents the editor (`editor.title` "New card") with empty fields and the front field focused; saving calls `POST /cards` and the new row appears at the top of the list | unit + UI |
| 7 | Tapping `study.add` presents the same editor ("New card") over study; saving dismisses it and, if study was caught up, study now shows the new card's front | unit + UI |
| 8 | `editor.save` is disabled while front or back is empty after trimming whitespace, and while a save is in flight | unit + UI |
| 9 | If saving fails, the editor stays open with the text intact and `editor.error` reads "Couldn't save. Check your connection." | unit |
| 10 | `editor.close` dismisses the editor without calling the API | unit + UI |
| 11 | Study refreshes after any change made in the deck or editor: App sends `study(.deckChanged)` when it receives `addCard(.delegate(.saved))` or `deck(.delegate(.deckChanged))`; deleting the current study card from the deck makes study show the next card once the deck is closed | unit (AppFeatureTests) + UI |
| 12 | The deck sheet closes by swiping down; rows and editor fields stay readable at Dynamic Type accessibility XL | UI |
| 13 | Live API (`scripts/e2e.sh`): add "chat"/"cat" from study → it appears in the deck list; delete it → gone after reopening the deck | UI (`_liveAPI`) |

## Screens & states
**Deck sheet** (ref 04, large detent, `Theme.background`): title row = `deck.title` "Cards" (`.screenTitle`)
left, `deck.add` circle button (`plus`) right (spec 003 adds `gearshape` next to it). Below: `deck.search`, a
plain text field on a `surface` capsule/row radius 12 with a `magnifyingglass` glyph, placeholder "Search".
Rows: `surface` fill, radius 12, 8pt gap, no separators, no list background. Inside: meta line (`.meta`,
`secondaryInk`) due left / state right; front `.body` `ink`; back `.body` `secondaryInk`; 1 line each.
`List` is fine (needed for `.swipeActions`) as long as it is restyled to look like the reference.
The swipe action is `Button("Delete", role: .destructive)` with no tint override: the system destructive red is
the one place color is allowed, so the ink tint is applied to the title row and search field, not the list.

**Editor sheet** (ref 03): `editor.title` (`.screenTitle`) top-left; top-right `editor.save` (`checkmark`)
and `editor.close` (`xmark`) circle buttons, xmark rightmost. Below: caption "Front" (`.meta`) + multiline
`editor.front`, caption "Back" + multiline `editor.back`, both `.body` `ink` on the background, no borders.
`editor.error` (`.meta`) under the fields when set.

Screenshots (light + dark unless noted): `deck`, `deck-search`, `deck-no-matches` (light), `deck-swipe`
(light, delete action visible), `editor-new`, `editor-filled` (light), `editor-edit`, `study-after-add`
(light), `deck-xl` (light), `deck-live` (light, e2e).

## TCA shape (iOS)
New modules (targets + test targets): `DeckFeature`, `CardEditorFeature`.
Dependency graph: `AppFeature → StudyFeature, DeckFeature, CardEditorFeature`; `DeckFeature → CardEditorFeature`.

**`CardEditorFeature`** (used by App for "add from study" and by Deck for add + edit)
- State: `let card: Card?` (nil = new card), `var front: String`, `var back: String`,
  `var isSaving = false`, `var saveFailed = false`; `init(card: Card? = nil)` prefills from `card`.
  Computed `canSave` (both trimmed non-empty, not saving).
- Actions (`BindableAction`): `binding`, `saveButtonTapped`, `closeButtonTapped`,
  `saveResponse(Result<Card, any Error>)`, `delegate(Delegate)`.
- Delegate: `case saved(Card)`.
- Dependencies: `\.apiClient` (`addCard` / `updateCard`), `\.dismiss`.
- On success: `.run { send in await send(.delegate(.saved(card))); await dismiss() }`.

**`DeckFeature`** (presented by App)
- State: `var cards: IdentifiedArrayOf<Card> = []`, `var query = ""`, `var phase: Phase = .loading`
  (`enum Phase { case loading, loaded, offline }`), `@Presents var destination: Destination.State?`.
- `@Reducer enum Destination { case editor(CardEditorFeature) }` (003 adds `settings`).
- Actions (`BindableAction`): `binding` (query → debounced fetch, `cancelInFlight`), `onAppear`,
  `addButtonTapped`, `rowTapped(Card.ID)`, `rowSwipedToDelete(Card.ID)`,
  `cardsResponse(Result<[Card], any Error>)`, `deleteResponse(Result<Card.ID, any Error>)` (the deleted id,
  so tests can receive `\.deleteResponse.success`),
  `destination(PresentationAction<Destination.Action>)`, `delegate(Delegate)`.
- Delegate: `case deckChanged` — sent after a successful save (from its editor) or delete.
- Editor `.saved(card)`: replace the row if it exists, else insert at index 0; then `.delegate(.deckChanged)`.
- Dependencies: `\.apiClient` (`cards`, `deleteCard`), `\.continuousClock`.

**`AppFeature`**
- State: `study`, `@Presents var destination: Destination.State?`.
- `@Reducer enum Destination { case deck(DeckFeature); case addCard(CardEditorFeature) }`.
- `study(.delegate(.deckRequested))` → `.deck(.init())`; `.addCardRequested` → `.addCard(.init())`.
- `destination(.presented(.addCard(.delegate(.saved))))` and `destination(.presented(.deck(.delegate(.deckChanged))))`
  → `.send(.study(.deckChanged))`.
- View: `.sheet(item: $store.scope(\.$destination, action: \.destination).deck)` and `.addCard`.

**`APIClient`**: live `cards` sends `limit=500` (the API max) so the deck isn't silently cut at 100. No API change.

## API / MCP changes
None (uses existing `/cards`, `POST /cards`, `PATCH`, `DELETE`).

## Accessibility identifiers
`deck.title`, `deck.add`, `deck.search`, `deck.message`, `deck.row.<card-id>` (row, tappable),
`deck.row.<card-id>.due`, `deck.row.<card-id>.state`, `deck.row.<card-id>.delete` (swipe action, label "Delete");
`editor.title`, `editor.front`, `editor.back`, `editor.save`, `editor.close`, `editor.error`.
Fixture ids are stable (`00000000-0000-0000-0000-00000000000N`).

## Out of scope
- Undo after delete, delete confirmation dialog, multi-select.
- Showing scheduling details (stability, review history) in the editor; deleting from the editor.
- Pagination beyond 500 cards (backlog).
- Settings button in the deck (spec 003).
