# 001 — Study session (home)

Status: done
Owners: api-engineer (small, first) / ios-engineer
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg
Changes (polish after QA): `study.remaining` and the rating row share the card text's `.accessibility2` Dynamic
Type cap; the card's scroll indicators flash on reveal so a back that runs past the screen shows it can scroll.
Superseded by 011: the rating row is two buttons ("Forgot" = again, "Got it" = good); hard/easy come from swiping.

## Goal
Opening the app drops the user straight into review: the due card's front centered, tap to reveal the
back, rate it, next card. When nothing is due, the screen says so and tells when the next card comes.
Covers backlog items 1 and 2. Replaces the walking-skeleton home of spec 000.

## User stories
- As the user, I open the app and immediately see the first due card's front.
- As the user, I tap to see the answer, then rate how well I knew it (again / hard / good / easy).
- As the user, when I'm done I see "All caught up" and when the next card will be due.
- As the user, I reach my deck (top-left) or add a card (top-right) from this screen.

## Acceptance criteria
Mock deck = `LA_CARTE_API=mock`, 3 fixture cards, all due, in fixture order (`serendipity`, `la carte`, `ephemeral`).

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | On launch with the mock deck, `study.front` shows "serendipity" centered horizontally, `study.remaining` reads "3 to review", `study.back` does not exist and `study.reveal` ("Show answer") is visible | unit + UI (light + dark) |
| 2 | Tapping `study.card` (anywhere in the middle area) **or** `study.reveal` shows `study.back` ("finding something good without looking for it") below the front; `study.reveal` disappears and the four rating buttons `study.rate.again/hard/good/easy` appear | unit + UI |
| 3 | Rating buttons do not exist before the reveal | UI |
| 4 | Tapping a rating sends `POST /cards/{id}/review` with that rating; while it is in flight the rating buttons are disabled; on success the next card's front shows unrevealed and `study.remaining` decrements ("2 to review") | unit + UI |
| 5 | After the last due card is rated, the app re-fetches due cards; if none, it fetches `/stats` and shows `study.message` "All caught up" and `study.nextDue` "Next card " + `next_due` formatted with `.relative(presentation: .numeric)` (e.g. "Next card in 23 hours"). `study.remaining`, `study.card` and rating buttons do not exist | unit + UI (mock: prefix "Next card in") |
| 6 | If `/stats` returns `next_due: null` (empty deck), `study.message` reads "No cards yet" and `study.detail` reads "Ask your agent to add some" (same copy as Deck and the widget; audit 2026-11-22) | unit |
| 7 | If loading due cards, stats, or a review fails, `study.message` reads "Can't reach your deck" and a `study.retry` circle button (`arrow.clockwise`) is shown; tapping it reloads due cards. After a failed review, a successful retry brings back the same card **still revealed** (the user already saw the answer; same rule as #9) | unit + UI (unreachable URL) |
| 8 | `study.deck` (top-left, `list.bullet`) and `study.add` (top-right, `plus`) are 44pt circle buttons visible in every state (studying, caught up, offline); tapping them sends `delegate(.deckRequested)` / `delegate(.addCardRequested)` (the screens they open arrive in spec 002) | unit (UI in 002) |
| 9 | Sending `.deckChanged` to Study re-fetches due cards without showing the loading state; if the first card is the same id as before, `isRevealed` is kept, otherwise it resets to `false` | unit |
| 10 | Against the live API seeded by `scripts/e2e.sh` (`bonjour`, `merci`): reveal + rate good twice → "All caught up" and `study.nextDue` starts with "Next card in" | UI (`_liveAPI`) |
| 11 | At Dynamic Type accessibility XL a revealed card with the rating row stays readable (no clipped/overlapping text); long text wraps and stays centered | UI |
| 12 | `GET /stats` and MCP `deck_stats` return `next_due`: the earliest `due` strictly after now, or `null` if no such card | pytest |

## Screens & states
Layout (Vyst editor, ref 01/02): `Theme.background` edge to edge. Top row: `study.deck` left, `study.add`
right, `study.remaining` (`.meta`, `secondaryInk`) centered on the same line. Middle: front in `.cardFace`
`ink`, centered; back appears below in `.body` `secondaryInk` with a 0.25s ease-in-out fade. The front never
moves on reveal: the back's space (and the rating row's) is reserved before reveal. Card text stops growing at
Dynamic Type `.accessibility2` and scrolls if it is still too long. Bottom slot:
before reveal a quiet text button "Show answer"; after reveal a row of four quiet text buttons
"Again" "Hard" "Good" "Easy" (`.body`, `ink`, no fills, no blue tint). Nothing else on screen.

- **loading**: background + corner buttons only.
- **studying**: as above.
- **caught up**: `study.message` "All caught up" in `.cardFace` centered, `study.nextDue` in `.meta` below.
- **offline**: `study.message` "Can't reach your deck" (`.body`), `study.retry` below.

Screenshots (light + dark unless noted): `study-front`, `study-revealed`, `study-caught-up`,
`study-offline` (light), `study-xl` (light, revealed), `study-live` (light, e2e, caught up).

## TCA shape (iOS)
- Module: `StudyFeature` (new target + `StudyFeatureTests`), child of `AppFeature` via `Scope(\.study, action: \.study)`.
- State:
  ```swift
  var cards: IdentifiedArrayOf<Card> = []   // due queue; first = current card
  var isRevealed = false
  var isReviewing = false                    // rating request in flight
  var phase: Phase = .loading
  enum Phase: Equatable { case loading, studying, caughtUp(nextDue: Date?), offline }
  ```
- Actions: `onAppear`, `cardTapped`, `revealButtonTapped` (both reveal; may share one case if the view
  sends the same action), `ratingTapped(Rating)`, `retryButtonTapped`, `deckButtonTapped`,
  `addButtonTapped`, `deckChanged` (sent by the parent), `cardsResponse(Result<[Card], any Error>)`,
  `statsResponse(Result<DeckStats, any Error>)`, `reviewResponse(Result<Card, any Error>)`, `delegate(Delegate)`.
- Delegate: `enum Delegate { case deckRequested, addCardRequested }`.
- Dependencies: `\.apiClient` (`dueCards(100)`, `review`, `stats`).
- Logic: due fetch → non-empty: `.studying`; empty: fetch stats → `.caughtUp(nextDue:)`. Review success removes
  the card, resets reveal; when the queue becomes empty, fetch due again (catches cards beyond the limit).
  Any failure → `.offline`. Shared fetch logic in a private helper, not an internal action.
- `AppFeature`: drops `stats`/`isOffline`; State becomes `study: StudyFeature.State` (spec 002 adds the
  destination). Until 002 lands, App returns `.none` for the two delegates. `AppView` renders `StudyView`.
- `APIClient`: `DeckStats` gains `nextDue: Date?`; `InMemoryAPIClient.stats` computes it (earliest `due > now`);
  in-memory `dueCards` keeps fixture order for equal `due` (stable). `DecodingTests` covers `next_due` set and `null`.

## API / MCP changes
`DeckStats` gains `next_due` (in `deck.stats`, so REST and MCP get it together):
```json
GET /stats → {"total": 3, "due": 0, "new": 0, "reviewed_today": 3, "next_due": "2026-11-22T09:00:00Z"}
```
`next_due` = `min(Card.due) where due > now`, `null` if none. MCP `deck_stats` docstring adds "and when the
next card not yet due becomes due (`next_due`, UTC, null if none)". pytest: deck-level with injected `now`,
plus REST and MCP shape.

## Accessibility identifiers
`study.deck`, `study.add`, `study.remaining`, `study.card` (tap area, contains front/back),
`study.front`, `study.back`, `study.reveal`, `study.rate.again`, `study.rate.hard`, `study.rate.good`,
`study.rate.easy`, `study.message`, `study.nextDue`, `study.retry`.

## Notes for QA
Spec 000 home criteria 1–3 (`app.title`, `app.summary`) are superseded by this spec: replace
`testHome_*` with `testStudy_*` and update the `-only-testing` list in `scripts/e2e.sh` accordingly
(coordinate with whoever owns that script). Gallery criteria (000 #4–5) are unchanged.

## Out of scope
- Undo last rating (`arrow.uturn.backward`), showing the next interval on rating buttons, swipe-to-rate.
- Refreshing when the app returns to the foreground (backlog).
- Offline review queue (backlog 9).
