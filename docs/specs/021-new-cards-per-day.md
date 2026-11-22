# 021 — Daily cap on new cards

Status: ready
Owners: api-engineer (no iOS change)
Depends on: 014a (notes, sibling hold) and 015a (reports), both merged. Backlog #43.
Design reference: none (no screen changes; the app keeps its "All caught up" / next-due screen, 001 / 018).

## Goal
Right now a new card is due as soon as it's added, so an agent that adds 60 notes floods the next session. With
this spec the server lets at most **N never-reviewed cards per day** into the study queue (Anki's "New
cards/day"). The rest wait their turn, oldest first. Agents can read and change N over MCP when the user asks
(user approval 2026-11-22).

## User stories
- As the user, I ask an agent to add 60 words, and my sessions over the next few days each bring about 15 new
  cards on top of my reviews.
- As the user, I tell my agent "only 5 new cards a day" or "pause new cards", and it changes the setting.
- As an agent, after `add_notes` I can tell the user how many cards wait and roughly for how many days.

## Decisions
1. **Default N = 15.** Each new card brings roughly 7–10 reviews a day in steady state. At 15 new cards a day that
   is about 100–150 short reviews, which takes about 10 minutes with minimalist cards. A 60-note batch is then
   introduced over 4 days. Anki's default is 20, but our cards are one fact each and sessions are meant to be
   short.
2. **Day = a rolling 24 h window** (`NEW_CARD_WINDOW = timedelta(hours=24)`). A card counts as **introduced** when
   its first `ReviewLog` row falls in `(now - 24 h, now]`. The rule is `introduced < N`. Why not a calendar day:
   `/cards/due` and `due_cards` carry no time zone, and only `/stats` gets `?tz`. A calendar day would need a
   stored time zone that goes stale when the user travels. The rolling window needs no new state and works the
   same for REST and MCP. The cost is a small drift: a slot frees exactly 24 h after the card that used it, so
   studying a bit earlier than yesterday can show "next at 08:05" for a few minutes.
3. **What counts.** Introductions are counted from `ReviewLog`, so a card introduced today and then deleted still
   used its slot. That's simple, and deleting can't game the cap. Cards already reviewed at least once
   (`last_review` not null) are **never held back** by the cap. That includes `learning` cards from today's new
   cards. Report-held new cards (spec 015) are ignored entirely: they take no slot and don't count as waiting.
4. **Order and siblings.** The allowed new cards are the first `N - introduced` never-reviewed cards in
   `_card_order` (oldest `created_at`, then the type's field order). Two exceptions: a note introduces **at most
   one card per window**, and a never-reviewed card is skipped while a sibling was introduced in the last 24 h or
   was already picked in this pass. So a person note's 3 directions arrive on 3 different days, like Anki's "bury
   new siblings". This rule replaces the 6 h hold for never-reviewed cards only; the spec 014 hold still applies
   on top. An allowed card that is buried right now keeps its slot. No look-ahead: the selection stays one simple
   pass.
5. **`next_due` stays truthful.** A waiting new card doesn't count as due and doesn't set `next_due`. The one
   exception is the time it **can** be let in: when a slot frees (the `(introduced - N + 1)`-th oldest
   introduction + 24 h) or when its sibling's window ends, whichever is later, and never before its normal
   `ready_at`. `next_due` is the earliest such time together with today's "later" times. With N = 0 (paused),
   waiting cards never set `next_due`. So "All caught up" + next due stays correct, and the app (018) reloads at
   a time when a card really becomes servable.
6. **No REST contract change.** `/cards/due`, `/stats` (`due`, `next_due`, `new`) and `/notes` keep their shape;
   their values follow the cap automatically. `stats.new` still counts all never-reviewed cards. The cap is
   MCP-only: no REST endpoint and no app setting (see Out of scope). So there's no `APIClient` /
   `DecodingTests` change and no e2e check.

## Storage
- `Settings` SQLModel table (`settings`): `id: int = 1` (primary key, single row), `new_cards_per_day: int = 15`.
  A missing row means the defaults. Read it with `session.get(Settings, 1) or Settings()`; a write upserts row 1.
- `deck.get_settings(session) -> Settings` and `deck.set_new_cards_per_day(session, n) -> NewCardsStatus`.
  The setter raises `InvalidSetting` (a `ValueError`) outside 0–200.
- **Migration 021** in `db._migrate`, same pattern as 015:
  `_rebuild_if(db, engine, "021", lambda: bool(_columns(db, "card")) and not _columns(db, "settings"), _create_settings)`.
  It creates the table only (no row). File databases get the usual `*.pre-021-<stamp>.bak` copy first.

## API / MCP changes
New model (in `models.py`), shared by the three MCP replies below:
```json
"new_cards": {
  "per_day": 15,          // the cap N (0 = paused)
  "introduced": 15,       // cards first reviewed in the last 24 h
  "available": 0,         // never-reviewed cards let into the queue now (servable or buried)
  "waiting": 45,          // never-reviewed cards held back by the cap or the one-per-note rule
  "days": 3               // ceil(waiting / per_day): rough, ignores the one-per-note rule; null when per_day = 0
}
```
`NewCardsStatus` is computed by `deck.new_cards_status(session, now)`, from the same selection `_queue` uses (one
helper, no second implementation).

MCP (`mcp_server.py`):
- **New tool `new_cards_per_day(value: int | None = None) -> NewCardsStatus`.** With no value it reads the
  setting; with a value it sets it. Docstring: "At most `per_day` never-reviewed cards enter study per rolling
  24 h, oldest first, one per note per day. 0 pauses new cards. Change it only when the user asks." An
  out-of-range value raises a tool error: "new_cards_per_day must be between 0 and 200 (0 pauses new cards)."
- **`deck_stats`** returns `AgentDeckStats(DeckStats)` with an extra `new_cards: NewCardsStatus`. REST `/stats`
  keeps `DeckStats`.
- **`add_notes`** returns `AddNotesReply(AddNotesResult)` and **`add_cards`** returns
  `AddCardsReply(AddCardsResult)`, each with `new_cards: NewCardsStatus` taken after the insert. The docstrings
  say "due immediately, subject to the daily new-card cap (see `new_cards`)". REST `POST /notes` and
  `POST /cards` keep their models.
- **`INSTRUCTIONS`** gets one line: "New cards: at most N per day enter study (default 15, oldest first); the rest
  wait. After adding, tell the user how many wait and for about how many days (`new_cards`). Change the cap with
  `new_cards_per_day` only when the user asks."

## Acceptance criteria
All are pytest, with `now` injected, in `deck` tests unless they name MCP.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Fresh DB: `new_cards_per_day()` returns `per_day = 15`. Add 20 one-card notes: `due_cards(limit=200)` holds the 15 oldest; `deck_stats` shows `due = 15`, `new_cards.waiting = 5`, `days = 1`, and `new = 20` | unit |
| 2 | Review 15 new cards at `t`: at `t + 1 min` no never-reviewed card is in the queue. At `t + 24 h + 1 s` the next 5 (oldest first) are | unit |
| 3 | Cards already reviewed are never held: 15 introductions today, then an old `review` card that is due and a `learning` card from today are both in the queue | unit |
| 4 | Siblings: a person note with 3 directions, all new and allowed by the cap. Only the first direction (field order) is servable on day 1; after it is reviewed, the second becomes servable only after 24 h from that first review, not after the 6 h hold | unit |
| 5 | A note with 2 never-reviewed cards and none introduced lets only 1 into the queue. A new card added (`add_direction`) to a note none of whose cards was introduced in 24 h is eligible at once (cap permitting) | unit |
| 6 | `next_due`: cap reached, nothing else due, new cards waiting. `stats.due = 0` and `next_due` = the oldest introduction in the window + 24 h. With N = 0 and only waiting new cards, `next_due` is null (or set by other cards only) | unit |
| 7 | `next_due` never points at a time when nothing becomes servable: at `next_due` from #6, `due_cards` returns ≥ 1 card | unit |
| 8 | Lowering the cap below today's introductions (15 → 5) introduces nothing more and holds back no started card. Raising it (5 → 30) lets more in at once | unit |
| 9 | `new_cards_per_day(0)` pauses: the queue has no never-reviewed cards, `days` is null. `new_cards_per_day(201)` and `(-1)` raise a tool error with the message above, and the setting is unchanged | MCP |
| 10 | The setting persists: set 7, open a new session/engine on the same file, read 7 | unit |
| 11 | Report-held new cards (015) take no slot and are not counted in `waiting` | unit |
| 12 | Introductions count from `ReviewLog`: deleting a card introduced today doesn't free its slot | unit |
| 13 | MCP `add_notes` with 60 basic notes on an empty deck replies `new_cards = {per_day: 15, introduced: 0, available: 15, waiting: 45, days: 3}`. `add_cards` carries `new_cards` too | MCP |
| 14 | REST is unchanged: `GET /stats` has exactly `{total, due, new, reviewed_today, next_due, streak}`, and `due` equals `len(GET /cards/due?limit=200)` with the cap applied | unit (REST client) |
| 15 | Migration 021: a pre-021 file DB (with `card`, without `settings`) gets the `settings` table and a `*.pre-021-*.bak` file; running again changes nothing; a fresh DB is created by `create_all` without a backup | unit |
| 16 | `INSTRUCTIONS` contains "new_cards_per_day" and "only when the user asks"; the `add_notes` docstring mentions the cap | unit (substring) |
| 17 | `docs/architecture.md` documents the cap (rolling 24 h, one per note, `next_due` rule), the `settings` table + migration 021, and the MCP tool and the extra `new_cards` fields | review |

## Screens & states
None. The existing Study states cover it: when only waiting new cards are left, the app shows "All caught up"
with the next-due time from #6. QA needs no new screenshots.

## TCA shape (iOS)
None.

## Accessibility identifiers
None.

## Out of scope
- An in-app setting or REST endpoint for the cap (backlog #44, only if the user asks).
- A calendar-day boundary or a stored time zone.
- A per-type cap, or a cap on reviews per day.
- Reordering waiting cards (priority or random order), or an MCP tool to "introduce this one now".
- Showing waiting counts in the app or the widget.
