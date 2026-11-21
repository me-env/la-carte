# 013 — Store the rating confidence with each review

Status: ready (API step now, after 012 merges; iOS step after 011 merges)
Owners: api-engineer (step 1) → ios-engineer (step 2)
Depends on: 012 (same `ReviewLog` + `db._migrate`), 011 (the drag value `v`). Backlog #22.
Design reference: none (no visible change).

**Parallelism.** Step 1 touches `api/src/la_carte_api/{models,db,deck,rest,mcp_server}.py`, `api/tests/`,
`docs/architecture.md`; runs next to any iOS work once 012 is merged. Step 2 touches
`ios/LaCarteKit/Sources/APIClient/**` (`review` signature, live + in-memory clients), `StudyFeature/**` (pass `v`
on drag release), `DecodingTests`/`StudyFeatureTests`; starts after 011 and must not overlap 009c (same files).

## Goal
FSRS takes four grades, but 011's drag measures a continuous confidence. Keep that value with each review so a
future scheduler or stats screen can use it. Collected data can't be recovered later, so we start storing it now.
Scheduling is unchanged: only `rating` drives FSRS.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `POST /cards/{id}/review` accepts `{"rating": "good", "confidence": 0.72}`; the new `ReviewLog` row has `confidence = 0.72` | pytest |
| 2 | `confidence` is optional: `{"rating": "good"}` still works and stores `NULL` (buttons, VoiceOver, agents) | pytest |
| 3 | `confidence` outside [0, 1] → 422; the card is not rescheduled and no log row is written | pytest |
| 4 | The rescheduled card for a given `rating` is identical with or without `confidence` | pytest |
| 5 | MCP `review_card(card_id, rating, confidence=None)` stores it the same way; its docstring says it's optional and only for a measured 0–1 value | pytest (MCP) |
| 6 | Migration: on a database without the column, startup adds `reviewlog.confidence` (nullable REAL) via `db._migrate`; existing rows read `NULL`; idempotent | pytest |
| 7 | iOS: `swipeEnded(fraction:)` (011) sends `confidence` = `ease(forSwipe: f)` rounded to 2 decimals together with the quantized rating; the two buttons and the VoiceOver actions send no `confidence` key | unit (`StudyFeatureTests`, mock `review` captures args) |
| 8 | iOS: the review request body encodes `confidence` only when non-nil | unit (`DecodingTests`) |
| 9 | Live E2E: rating by drag against the live API still advances to the next card (no contract break) | UI (`_liveAPI`, existing 011 live test) |

**Supersedes 011 #6's "The request body has only `rating`"** for drag releases: QA updates that stub assertion to
expect `confidence` too (buttons still send only `rating`).

## TCA shape (iOS)
- `APIClient.review: (Card.ID, Rating, Double?) async throws -> Card` (in-memory client ignores the value).
- `StudyFeature`: `swipeEnded(fraction:)` already computes the ease; pass it through. Button and accessibility
  paths pass `nil`. No new state, no new actions.

## API / MCP changes
- `ReviewCreate`: `confidence: float | None = Field(default=None, ge=0, le=1)`.
- `ReviewLog`: `confidence: float | None = None`.
- `deck.review_card(session, card_id, rating, now=None, confidence=None)`.
- Response unchanged (`Card`). `docs/architecture.md` REST table: body `{rating, confidence?: 0–1}`.

## Accessibility identifiers
None.

## Out of scope
Using confidence in scheduling or stats; exposing it in responses; any UI showing it.
