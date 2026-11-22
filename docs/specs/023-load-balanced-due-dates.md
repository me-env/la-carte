# 023 — Spread due dates (load balancing)

Status: in-review (QA: validation is the pytest suite `api/tests/test_balance.py`, no screenshots)
Owners: api-engineer (no iOS change)
Depends on: nothing new (touches `deck.review_card` only). Runs in parallel with 021 (API part) and 022, which
change the queue (`deck._queue`), not scheduling. Backlog #47.
Design reference: none (scheduling only, no screen changes).

## Goal
When a review gives a card an interval of several days, the server may move its due date by a few days, within a
window proportional to the interval, toward the days that already have fewer cards due. Busy days and empty days
even out over time, without the user setting a daily capacity. Approved by the user 2026-11-22: Anki's fuzz
ranges, with Anki 24.11's load balancer picking the day.

## User stories
- As the user, an agent added 80 cards on Sunday and I learned them all. Their reviews don't all land on the same
  day next week: they spread over the days around it.
- As the user, I never configure anything: the spreading only compares a day with its neighbours.

## What exists today (checked in `fsrs` 6.3.3, `api/.venv/.../fsrs/scheduler.py`)
`deck._scheduler = fsrs.Scheduler()` has `enable_fuzzing=True` by default, so **fuzz is already live**:
`Scheduler.review_card` calls `_get_fuzzed_interval` when the card ends in `State.Review`. That function:
- leaves intervals under 2.5 days alone;
- builds the window `[round(i - delta), round(i + delta)]` with `delta = 1 + Σ factor × overlap(i, range)` over
  the module constant `fsrs.scheduler.FUZZ_RANGES` (2.5–7 d: 0.15, 7–20 d: 0.10, 20 d+: 0.05), lower bound at
  least 2, upper bound at most `maximum_interval` (36500);
- picks a day **uniformly** with the global `random.random()` (not seedable per call).

That window is exactly the one the user approved. What's missing is the weighting (the library picks uniformly)
and a seedable RNG. So this spec turns the library's fuzz off and does the pick itself, over the same window.

## Decisions
1. **When.** Only when `Scheduler.review_card` returns a card in `State.Review` (the same condition as the
   library's fuzz): a review card rated Hard / Good / Easy, a learning card graduating to review, a relearning
   card graduating back. Learning / relearning steps (minutes) and new cards (due at creation) are never moved.
2. **Unbalanced interval.** `_scheduler = fsrs.Scheduler(enable_fuzzing=False)`. Then
   `i = (scheduled.due - now).days` is FSRS's own interval in whole days (the library schedules review intervals as
   whole days, so `due - now` is an exact multiple of a day). If `i < 3` (the library's "< 2.5 days"), keep `due`.
3. **Window.** `_balance_window(i) -> (lo, hi)` reproduces the library's bounds, reading `FUZZ_RANGES` from
   `fsrs.scheduler` (reuse, don't copy the numbers) and `_scheduler.maximum_interval`. Examples:
   3 → (2, 4), 20 → (17, 23), 100 → (93, 107), 365 → (345, 385).
4. **Days are counted relative to the review instant, not to a calendar.** Candidate day `k` means
   `due = now + k days` (time of day kept, as FSRS does today). Its load = the number of other cards with
   `now + (k-1) days < due <= now + k days`. Why: the server has no reliable time zone at review time
   (`POST /cards/{id}/review` and MCP `review_card` carry none; only `/stats` calls do, and storing the last one
   would add state for little gain). A 24-hour bucket ending at the candidate due is what the user would find
   waiting if they came back at the same time of day, which is the habit spaced repetition assumes. It needs no
   settings and no stored time zone. Buckets are compared only with their neighbours, so a shifted boundary
   barely matters.
5. **Which cards count.** Every card in the deck (one deck, any state) except the card being reviewed. In practice
   only `review` cards fall in a window that starts at least 1 day ahead: new cards are due at creation, (re)learning
   cards within minutes. Report-held cards (015) and sibling holds (014) are ignored: they don't change a card's
   `due`, and keeping the query to a single column is simpler.
6. **One query per review.** `select(Card.due).where(Card.due > now + (lo-1) days, Card.due <= now + hi days,
   Card.id != card.id)` (uses the existing index on `card.due`), bucketed in Python. Window width: 3 days at 3 d,
   41 at 1 y. Nothing is cached, nothing is stored.
7. **Weight, as in Anki 24.11** (`rslib/src/scheduler/states/load_balancer.rs`, `select_weighted_interval`):
   `weight(count, k) = 1.0` if `count == 0`, else `(1 / count) ** 2.15 * (1 / k) ** 3`. Pick one `k` with
   `rng.choices(range(lo, hi + 1), weights)`. Emptier days win most of the time; the `1/k³` term slightly prefers
   the shorter (safer) end of the window; it stays random, so no single day collects all the cards. With an empty
   window every weight is 1: a uniform pick, exactly what the library's fuzz does today.

   Not taken from Anki: its 90-day cutoff (an artefact of its precomputed 99-day cache; our query is per review,
   so we balance at every interval), its sibling modifier (spec 014's sibling hold already separates siblings), and
   "easy days" (no per-weekday settings here).
8. **Fresh every time, no drift.** The window is centred on this review's FSRS interval, computed from the card's
   stability at `now`. The shift isn't stored anywhere (no column, no migration), and the next review starts from
   FSRS again. The only lasting effect is the real elapsed time FSRS sees at the next review, as with any fuzz.
9. **Deterministic in tests.** `deck.review_card(..., rng: random.Random | None = None)`. If it's `None`, it uses a
   module-level `_rng = random.Random()`. Tests pass `random.Random(seed)`. REST and MCP pass nothing. The library's
   global `random` is no longer used (fuzzing is off).
10. **No contract change.** `POST /cards/{id}/review` and MCP `review_card` both call `deck.review_card` and keep
    their request and response shapes; the response already carries the new `due`. No `APIClient` /
    `DecodingTests` / iOS change. No MCP instruction change: agents don't need to know.
11. **No overlap with 021 / 022.** Those specs change which cards are servable and in what order (`deck._queue`,
    `/stats`). This spec only changes the `due` written by `review_card`. Neither reads the other's code.
    `get_card_retrievability` (022) doesn't depend on `enable_fuzzing`.

## API / MCP changes
None to shapes or tools. Internal only, in `api/src/la_carte_api/deck.py`: `_scheduler` without fuzzing,
`_rng`, `_balance_window`, `_day_weight`, the one count query, `review_card(rng=...)`. `docs/architecture.md`
gains one "Due-date spreading (spec 023)" bullet (in this change).

## Acceptance criteria
All pytest, `now` injected, `rng=random.Random(seed)`, in `api/tests/test_deck.py` or a new
`api/tests/test_balance.py`. The reference interval is the one from a `fsrs.Scheduler(enable_fuzzing=False)` on
the same card state.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | A new card rated Good, then Again on a review card (relearning): `due` equals `now + the step` exactly (minutes), for any seed | unit |
| 2 | A review whose reference interval is 1 or 2 days: `due == now + reference interval` exactly, for 20 seeds | unit |
| 3 | `_balance_window`: 3 → (2, 4), 20 → (17, 23), 100 → (93, 107), 365 → (345, 385); `hi` never exceeds `_scheduler.maximum_interval` | unit |
| 4 | For a review with a reference interval of 3 days or more, over 50 seeds: `due - now` is a whole number of days within `_balance_window(reference)` | unit |
| 5 | `_day_weight(0, k) == 1.0`; `_day_weight(4, 10) == (1/4) ** 2.15 * (1/10) ** 3` | unit |
| 6 | Prefers the light day: reference interval 20, every day 17–23 has 20 other cards due except day 21 (0 cards). Over 100 seeds (fresh fixture each), day 21 is picked at least 90 times | unit |
| 7 | Still random: same fixture with every day 17–23 equally loaded, 50 seeds give at least 3 distinct days | unit |
| 8 | Deterministic: same fixture, same `now`, same seed → same `due`, twice | unit |
| 9 | Bucket boundaries: a card due exactly `now + k days` counts for day `k`, one due `now + (k-1) days` counts for day `k-1`, and the reviewed card's own old `due` isn't counted (checked through the counting helper or through the pick, with one day loaded at a time) | unit |
| 10 | No drift: a review card whose current `due` was shifted +3 days from its last interval gets a window centred on the reference interval computed at `now`, not on the shifted date; the `card` table schema is unchanged | unit |
| 11 | One query: a review that gets balanced runs exactly one `SELECT` on `card` with a `due` range beyond what an unbalanced review (interval < 3 d) runs (count statements with a SQLAlchemy `before_cursor_execute` listener) | unit |
| 12 | Performance: 5,000 review cards due over the next 400 days (in-memory DB), one `review_card` with a reference interval near 365 days takes < 200 ms | unit |
| 13 | REST `POST /cards/{id}/review` and MCP `review_card` still return the same JSON keys, and their `due` lies within the window of AC 4; existing contract tests pass unchanged | REST client + MCP |

## Screens & states
None. No screenshots: QA validation is the pytest suite (the app shows whatever `due` the API returns).

## TCA shape (iOS)
None.

## Accessibility identifiers
None.

## Out of scope
- A daily capacity or review cap (rejected; the balancer is relative only).
- Rebalancing existing cards in bulk, or moving cards when a day gets busy later (each review is balanced once).
- Easy days / per-weekday load, sibling-aware spreading, time-zone-aware buckets.
- Queue order (specs 021, 022) and what `/stats` counts.
- Showing the shift in the app or over MCP.
