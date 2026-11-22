# 022 — Risk-first order of due reviews

Status: ready
Owners: api-engineer (no iOS change)
Depends on: 014a (notes, sibling hold), 015a (reports), 021 hotfix (new cards never held), all on main. Backlog #45.
Design reference: none (ordering only, no screen changes).

## Goal
When several review cards are due, the server serves the one **most at risk of being forgotten** first: the lowest
current FSRS retrievability (Anki's "relative overdueness" / "retrievability ascending" sort), instead of the oldest
due date. It matters most after a break with a big backlog: the cards you are about to lose come first, and the
ones that can wait come last. Ordering only (user approval 2026-11-22: "only about ordering the cards"). No review
cap, and no card is hidden or held back by this spec.

## User stories
- As the user, back after two weeks off with 300 due reviews, my first 10 minutes go to the cards I'm closest to
  forgetting, not to the ones that happened to fall due first.
- As an agent running `quiz_me`, `due_cards` gives me the riskiest cards first, so a short quiz is a useful one.

## Decisions
1. **One order for the whole servable queue**, in three groups:
   1. **(Re)learning cards**, earliest `due` first. They are in progress, due in minutes, and their stability is
      the lowest of all; serving them first keeps the learning steps on time. Unchanged from today's rule that a
      (re)learning card is never held and wins within its note.
   2. **Review cards**, lowest retrievability at `now` first.
   3. **New cards** (never reviewed): placement per spec 021. Spec 021 is being reworked after the hotfix (new cards
      are never held). Until it says otherwise, new cards come **after all reviews, oldest first** (`_card_order`).
      If the 021 rework places them elsewhere, only the group rank of new cards changes; groups 1 and 2 stay as
      here. Note for the 021 architect: with a large review backlog this puts new cards at the end of a long queue
      (they stay servable and are counted in `stats.due`; they are not hidden).
2. **Retrievability** = `fsrs.Scheduler.get_card_retrievability(card.to_fsrs(), now)` with the module's
   `_scheduler`. Use the library's function; don't copy the formula. It counts whole elapsed days, so ties are
   common; that's fine (see 4).
3. **Within a note the same order picks the winner.** The spec 014 rule "at most one card per note: a (re)learning
   card wins, then the most overdue" becomes "a (re)learning card wins, then the lowest retrievability", and a due
   review sibling now wins over a new sibling. The sibling hold itself (`SIBLING_BURY`, `ready_at`) is unchanged, so
   which cards are servable, `stats.due` and `stats.next_due` don't change: only their order does.
4. **Ties and determinism.** One sort key, used both for the per-note pass and for the final order (so the second
   sort in `_queue` goes away):
   `(group, retrievability or 0.0, due, *_card_order(card, note), str(card.id))`, with group 0 = (re)learning,
   1 = review, 2 = new. Ties fall back to the earlier `due`, then the oldest card / field order, then the card id,
   so the same deck at the same `now` always gives the same order.
5. **Performance.** Retrievability is computed once per card per request, inside the existing single pass over
   `Card ⋈ Note` (pure arithmetic, no extra query). Cost: O(n log n) for n cards, a few ms for a few thousand. No
   index, cache or stored column.
6. **No contract change.** `GET /cards/due` and MCP `due_cards` both call `deck.due_cards`, so they return the same
   order; their JSON is unchanged. `/stats` values are unchanged (decision 3). No `APIClient` / `DecodingTests` /
   iOS change: the app already serves `/cards/due` in the order received.

## The queue, in one place (as of this spec)
Servable = not held by an active report (015), `ready_at(card) <= now` (014 sibling hold; (re)learning never held),
every new card included (021 hotfix), at most one card per note. Order: (re)learning by `due` → reviews by
retrievability ascending → new cards per spec 021 (for now: after reviews, oldest first). Ties as in decision 4.

## API / MCP changes
None to shapes. Text only:
- MCP `due_cards` docstring and the `INSTRUCTIONS` quiz line say the cards come "most at risk of being forgotten
  first".
- `docs/architecture.md` "Sibling burying" paragraph: replace "most overdue first" / "then the most overdue" with
  the order above.

## Acceptance criteria
All pytest, `now` injected, in `api/tests/test_deck.py` (or a new `test_order.py`) unless they name REST or MCP.
Build review cards through `review_card` at chosen times, or by setting `stability` / `last_review` / `due`
directly.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Two due review cards on different notes: A: stability 100, last review 110 days ago, due 10 days ago (elapsed/stability = 1.1); B: stability 2, last review 4 days ago, due 1 day ago (elapsed/stability = 2, so lower R). `due_cards()` returns B before A, the reverse of the old due-date order | unit |
| 2 | Retrievability of the served order is non-decreasing: 30 review cards with random stability / last review, all due, on separate notes: `[R(c, now) for c in due_cards(limit=200)]` is sorted ascending | unit |
| 3 | A `relearning` card (just failed) and a `learning` card, both due, come before every due review card, even one with retrievability near 0; among them the earlier `due` comes first | unit |
| 4 | New cards come after all due reviews, oldest first (interim per 021; update this criterion if the 021 rework moves them) | unit |
| 5 | Within a note: two due review siblings, neither held. Only the one with the lower retrievability is served (not the more overdue one). A due review sibling wins over a new sibling. A (re)learning sibling still wins over both | unit |
| 6 | The sibling hold is unchanged: after reviewing a card of a note, its sibling with the lowest retrievability in the deck is still absent until the hold ends; `stats.due` and `stats.next_due` equal their values before this change for the same fixture | unit |
| 7 | Ties: two review cards with equal stability and the same last-review day (equal R) come out by earlier `due`; with equal R and `due`, by `_card_order` then id. Calling `due_cards` twice at the same `now` gives the same list | unit |
| 8 | `limit` takes the head of the ordered queue: with 50 due reviews, `due_cards(limit=5)` equals the first 5 of `due_cards(limit=200)` | unit |
| 9 | REST and MCP agree: same fixture, `GET /cards/due?limit=200` ids == MCP `due_cards(limit=200)` ids == `deck.due_cards` ids, and the REST JSON keys are unchanged | REST client + MCP |
| 10 | Report-held cards (015) are still absent and don't affect the order of the rest | unit |
| 11 | Performance: 3,000 due review cards on separate notes (in-memory DB): one `due_cards(limit=200)` call takes < 1 s | unit |
| 12 | MCP `due_cards` docstring contains "most at risk"; `docs/architecture.md` states the order (learning → retrievability → new per 021) | unit (substring) + review |

## Screens & states
None. QA needs no screenshots; the app shows `/cards/due` in the order it gets.

## TCA shape (iOS)
None.

## Accessibility identifiers
None.

## Out of scope
- A cap on reviews per day, or hiding / postponing any card (rejected by the user, see 021).
- Where new cards sit relative to reviews beyond the interim rule (spec 021 owns it).
- Random or interleaved ordering, per-type priority, "load balancing" of future due dates.
- Desired-retention settings, FSRS parameter optimisation.
- Showing retrievability in the app or over MCP.
