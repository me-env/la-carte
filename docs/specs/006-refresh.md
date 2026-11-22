# 006 — Refresh: pull-to-refresh + reload on foreground

Status: done (pull-to-refresh removed by [018](018-auto-refresh.md); the foreground reload and the refresh rule stay)
Owners: ios-engineer
Depends on: 001 (Study, `deckChanged` reveal rule), 002 (Deck)
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg (study), 04-list-dark.jpg (deck).
No new visuals: the system refresh spinner is the only addition.

## Goal
Cards added by an agent (MCP) while the app is open show up without relaunching: the user pulls down on
Study or on the Cards list, or simply comes back to the app. Covers backlog item 11, widened to pull-to-refresh
and to the deck.

## User stories
- As the user, after my agent adds cards, I pull down on the study screen and the new cards are in my queue.
- As the user, I pull down on the Cards list and see the cards my agent just added.
- As the user, I switch back to the app and it is already up to date, without losing the answer I had revealed.

## The refresh rule (one rule, both triggers)
A refresh is a **quiet reload**: it re-fetches the screen's data with no loading state; the current content
stays on screen until the response replaces it.
- **Study** reloads due cards exactly like `deckChanged` (spec 001 #9): if the first card after the reload is the
  same id as before, it **stays revealed** (back and rating buttons stay); if it changed (reviewed or deleted
  elsewhere), the new first card shows unrevealed. New cards are due "now", so they join the end of the queue and
  the card being studied doesn't change.
- **While a rating is in flight** (`isReviewing`), Study ignores the refresh: the review's response updates the
  queue, and skipping avoids a stale list bringing back the card just rated.
- **Deck** reloads with the current search query (the field keeps its text).
- Triggers: pull-to-refresh, and the scene becoming `.active`. Every transition to `.active` reloads (also at
  launch and after Control Center): such reloads are harmless because they are quiet and a newer load cancels an
  older one.
- Study refreshes on foreground even when a sheet covers it, so it is current when the sheet closes; the deck
  refreshes only while it is presented (its view only exists then).
- A failed refresh behaves like any failed load: Study → offline (`study.message` + `study.retry`),
  Deck → "Can't reach your deck".

## Acceptance criteria
Mock deck = `LA_CARTE_API=mock`. "Stub" = `StubAPIServer` in the UI-test runner (the in-memory mock lives in the
app process, so the test can't add cards to it); the test changes the stub's handler to simulate an agent adding
a card.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Study, caught up (stub: no due cards): adding a card on the stub, then pulling down on the screen shows that card's front in `study.front`, unrevealed, and `study.remaining` "1 to review". No loading state (blank screen) shows during the pull | unit + UI (light + dark) |
| 2 | Study, offline (`study.message` "Can't reach your deck"): pulling down reloads like `study.retry`; when the API answers, the screen leaves the offline state | unit + UI (stub down then up) |
| 3 | Study, studying with the first card revealed: a refresh whose first card is the same id keeps `study.back` and the four rating buttons visible and updates `study.remaining` (e.g. "1 to review" → "2 to review"); a refresh whose first card differs shows the new first card unrevealed | unit + UI (foreground case, stub) |
| 4 | Study: a refresh (pull or foreground) while a rating is in flight does not call the API and changes no state | unit |
| 5 | Study: when the scene becomes `.active`, due cards are reloaded with the rule above; `.inactive` and `.background` do nothing. UI: stub caught up → add a card on the stub → Home → reactivate the app → the card's front shows | unit + UI (stub) |
| 6 | Study: a new load (refresh, retry, `deckChanged`, onAppear) cancels a load still in flight, so an older response never overwrites a newer one | unit |
| 7 | Study: pull-to-refresh works in every non-loading state (studying, caught up, offline). In studying, the pull surface is the card area (`study.card`); pulling does **not** reveal the card, and the front still does not move on reveal (001) | UI |
| 8 | Deck: pulling down on the list (or on `deck.message`) reloads `GET /cards` with the current query; existing rows stay until the response replaces them. UI (stub): "No cards yet" → add a card on the stub → pull on `deck.message` → `deck.row.<id>` appears | unit + UI (light + dark) |
| 9 | Deck: when the scene becomes `.active` while the deck is presented, it reloads with the current query. UI (stub): deck open → add a card on the stub → Home → reactivate → the new row appears | unit + UI (stub) |
| 10 | Deck: a refresh does not send `delegate(.deckChanged)` (nothing changed locally) and does not touch `query` | unit |
| 11 | The refresh spinner is not blue (system gray or ink) in light, dark and forest | screenshot review |
| 12 | Live API (`scripts/e2e.sh`, seeded `bonjour`, `merci`): with the app open on Study ("2 to review"), open the deck, `POST /cards` "chien"/"dog" from the test runner, pull the list → the `chien` row appears; close the deck, pull Study → `study.remaining` "3 to review" and `study.front` is still `bonjour`. The test then deletes `chien` via `DELETE /cards/{id}` so the deck is left as seeded | UI (`_liveAPI`) |

## Screens & states
No layout change visible at rest. What changes:
- **Study**: `.refreshable` on the content area. The caught-up, offline and (empty) loading content sit in a
  vertical `ScrollView` that fills the content area and keeps the message centered, so they can be pulled. In
  studying, the card's existing `ScrollView` is the pull surface: it must bounce even when the text fits
  (today `.scrollBounceBehavior(.basedOnSize)` prevents a pull on short cards). The rating row stays pinned
  below the card, outside the scroll view, as today.
- **Deck**: `.refreshable` on the `List`; the `deck.message` state also sits in a scroll view that can be pulled.
- Foreground: no UI at all, the content just updates.
- Spinner: the system refresh control; must not pick up the default blue tint (design-system "accent = ink").

Screenshots (light + dark unless noted): `study-after-refresh` (#1, card shown after the pull),
`study-foreground-revealed` (light, #3/#5: revealed card kept, "2 to review"), `deck-after-refresh` (#8),
`study-refresh-live` (light, #12), `deck-refresh-live` (light, #12), `study-refresh-forest` (forest, spinner
visible mid-pull, best effort for #11).

## TCA shape (iOS)
No new module, no App change: each screen observes the scene phase itself, so "the visible screen" falls out of
the view tree (the deck view only exists while presented; Study is always mounted).

**`StudyFeature`**
- State: unchanged.
- Actions (new): `pulledToRefresh`, `scenePhaseChanged(ScenePhase)` (`import SwiftUI` for `ScenePhase`).
- `pulledToRefresh`, `scenePhaseChanged(.active)`: `guard !state.isReviewing else { return .none }`, then
  `fetchDueCards()` without touching `phase` (same path as `deckChanged`; the existing `cardsResponse` already
  keeps `isRevealed` when the first id is unchanged). Other phases → `.none`.
- `fetchDueCards()` becomes `.cancellable(id: CancelID.load, cancelInFlight: true)` (one shared id, like Deck).
- View: `@Environment(\.scenePhase)`; `.onChange(of: scenePhase) { _, phase in store.send(.scenePhaseChanged(phase)) }`;
  `.refreshable { await store.send(.pulledToRefresh).finish() }` so the spinner stays until due cards arrive
  (the follow-up `/stats` call for caught up may land just after; that's fine).

**`DeckFeature`**
- State: unchanged.
- Actions (new): `pulledToRefresh`, `scenePhaseChanged(ScenePhase)`.
- `pulledToRefresh`, `scenePhaseChanged(.active)` → `loadCards(matching: state.query)` (already cancel-in-flight,
  also cancels a pending debounced search, which it supersedes). Other phases → `.none`.
- View: same `scenePhase` observer and `.refreshable { await store.send(.pulledToRefresh).finish() }`.

**Tests** (`StudyFeatureTests`, `DeckFeatureTests`): one per logic criterion — #1 (caught up → studying, no
`.loading`), #2, #3 (same first id keeps reveal; different id resets), #4 (no effect while reviewing),
#5 (`.active` reloads, `.inactive`/`.background` don't), #6 (second load cancels the first: `dueCards` suspended
on a `TestClock`, only one `cardsResponse` received), #8/#9 (reload with the query, rows kept until response),
#10 (no delegate).

## API / MCP changes
None. Uses `GET /cards/due`, `GET /stats`, `GET /cards`.

## Accessibility identifiers
None new. Pulls start on existing elements: `study.card`, `study.message`, `deck.row.<id>`, `deck.message`.

## Notes for QA
- Pull gesture: `press(forDuration: 0.05, thenDragTo:)` from the element to ~60% lower, then wait for the
  expected label (a shared `pullToRefresh` helper in `Support.swift` is welcome).
- Foreground: `XCUIDevice.shared.press(.home)`, then `app.activate()`.
- The live test (#12) adds and removes `chien`, so it is deck-neutral; add it to the `-only-testing` list in
  `scripts/e2e.sh`, before `testStudy_revealRateToCaughtUp_liveAPI`, which expects exactly the seeded two cards.

## Out of scope
- Push / polling / server-sent updates while the app stays in the foreground untouched (pull or foreground only).
- Refreshing the card editor or Settings sheets.
- The narrow race where a deck refresh started before a swipe-delete completes briefly shows the row again (the
  delete's own reload corrects it, spec 002 #4); same for the existing `deckChanged` vs in-flight review race.
- Any visual indicator of "new cards" or a last-updated time.
