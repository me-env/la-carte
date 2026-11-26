# 031 — MCP cleanup: drop the legacy card tools, add review history

Status: ready
Owners: api-engineer → code-reviewer → qa-validator (pytest only, no UI)
Depends on: 029 API (branch `worktree-agent-acbdf640e1bc2e82a`, adds `activity_log`) and 028 API (edits the
`find_notes` description) merged first: all three edit `mcp_server.py`. Before or after 030a (see "Accounts").
Design reference: none (no screen, no app change).

## Goal
Agents see one clear set of tools: the note tools, the quiz, reports, feedback and history. The four card-level
tools left over from before notes (spec 014) go. Agents can answer "which cards do I fail most", "what did I study
yesterday" and "why didn't I see the card I just created" from dated records, without analytics on the server.

User requests (2026-11-26, verbatim):
- "I think we have some outdated MCP tools and we should delete them."
- "Since we now log a lot of the things the user does, he might want to ask questions about cards he fails
  frequently and these kinds of things. So just these logs, I think we can make them accessible via the MCP."

## User stories
- As the user, I ask my agent "which cards do I keep failing?" and get a ranked list with the card text.
- As the user, I ask "what did I study yesterday?" and get the cards and how I rated them.
- As the user, I ask "why don't I see the card I just created?" and the agent explains it from the note's schedule
  and what the app did.
- As an agent, I'm not offered two tools for the same job (`add_cards` vs `add_notes`).

## Decisions

### 1. Tool and prompt audit (main + the 029 branch)

| Tool / prompt | Decision | Why |
|---|---|---|
| `add_notes` | keep | The way to add. One `front -> back` card = `directions: [{"prompt": ["front"]}]` |
| `find_notes` | keep | Lookup and duplicate check; returns every card id and schedule |
| `update_note` | keep | Fixes text for every sibling |
| `add_direction` | keep | |
| `remove_direction` | keep | |
| `delete_note` | keep | |
| `add_cards` | **delete** | Superseded by `add_notes` (spec 014); its docstring already says "Prefer the note tools". Two add paths with different defaults (one card vs both directions, spec 026) confuse agents |
| `list_cards` | **delete** | Superseded by `find_notes` (same `query`, returns the cards inside each note) |
| `update_card` | **delete** | Superseded by `update_note` (and refuses multi-field sides anyway) |
| `delete_card` | **delete** | Superseded by `remove_direction` (one card) and `delete_note` (all). `update_report(deleted)` keeps its own delete |
| `due_cards` | keep | Quiz flow; nothing replaces it |
| `review_card` | keep | Quiz flow |
| `deck_stats` | keep | Counts, streak, per-day `history` |
| `new_card_milestone` | keep | |
| `list_reports`, `update_report` | keep | Report handling (spec 015) |
| `send_feedback`, `list_feedback`, `close_feedback` | keep | Spec 025; owner triage in 030a decision 9 |
| `activity_log` (029) | keep, unchanged | What the app did (shown, revealed, timings, queue fetches, errors); app only, no card text, 90 days |
| `review_history` | **new** | Every rating ever, app or agent, with the card text (decision 2) |
| `struggling_cards` | **new** | The one convenience ranking (decision 3) |
| prompts `quiz_me`, `make_cards`, `add_people`, `handle_reports` | keep, text unchanged | None mentions a deleted tool (checked: they use `due_cards`, `review_card`, `deck_stats`, `find_notes`, `add_notes`, `update_note`, `list_reports`, `update_report`) |

Final tool list (18): `add_notes`, `find_notes`, `update_note`, `add_direction`, `remove_direction`, `delete_note`,
`due_cards`, `review_card`, `deck_stats`, `new_card_milestone`, `list_reports`, `update_report`, `send_feedback`,
`list_feedback`, `close_feedback`, `activity_log`, `review_history`, `struggling_cards` (030a adds none).
Prompts: the same 4.

REST is **not** touched: `POST/GET /cards`, `PATCH/DELETE /cards/{id}` stay for old app builds, the UI-test stub
(`ios/LaCarteUITests/StubAPIServer.swift`) and the e2e seeding (`scripts/e2e.sh` posts `/cards`). So `deck.add_cards`,
`deck.list_cards`, `deck.update_card`, `deck.delete_card`, `CardCreate`, `CardUpdate`, `AddCardsResult` stay (REST
and pytest fixtures use them). Only `AddCardsReply` (MCP-only model) is deleted.

### 2. `review_history`: raw dated ratings over `ReviewLog`
Gap check against 029 + the existing tools:
- `activity_log` `rated` events carry `card_id` + rating + timings but **no card text**, only **app** ratings (an
  agent's `review_card` quiz is not in it), and only **90 days**.
- `ReviewLog` holds every rating from both the app and MCP, forever (spec 012), but nothing exposes it; `deck_stats`
  only gives per-day letters.
- Resolving a `card_id` to its text needs `find_notes` paging (newest 50) — unusable for history.

So one tool over `ReviewLog`, joined to the card's current text:

```
review_history(since=None, until=None, card_id=None, note_id=None, rating=None, limit=100) -> list[ReviewEntry]
```
- Newest first (`reviewed_at` desc, then `ReviewLog.id` desc). `since <= reviewed_at < until`; ISO 8601, naive =
  UTC, offsets accepted (same parsing as `activity_log`, `deck._utc`). `since > until` → `[]`.
- `card_id`: that card's reviews. `note_id`: reviews of the note's **current** cards (a removed direction's
  reviews only show unfiltered or by `card_id`). Both given → AND. `rating`: `again | hard | good | easy`.
- `limit`: 1–1000 (`Field(ge=1, le=1000)`, out of range = validation error), default 100.
- `ReviewEntry` = `{card_id, reviewed_at, rating, confidence, card}`; `card` = the current `Card` (same `CardRead`
  as `due_cards`: `note_id`, `prompt`, `answer`, `fields`, `front`, `back`, `state`, `due`, …) or `null` once the card
  was deleted. `stability_before` / `last_review_before` stay internal.
- Read-only. Unknown `card_id` / `note_id` → `[]` (not an error: a deleted card still has history).

### 3. `struggling_cards`: the single convenience ranking
```
struggling_cards(since=None, limit=20) -> list[StrugglingCard]
```
- A "fail" is an `again` rating (`ReviewLog` has no lapse counter; `again` during learning counts too, kept simple).
- Over reviews with `reviewed_at >= since` (all history when null), per **existing** card with at least one
  `again`: `StrugglingCard` = `{card, reviews, again, last_again_at}` (`card` = `CardRead`, `reviews` = all ratings
  of that card in the window).
- Order: `again` desc, then `again / reviews` desc, then `last_again_at` desc, then `card.id` (stable).
- `limit` 1–100, default 20. Read-only. Deleted cards are left out (nothing to act on). No other aggregates.

### 4. INSTRUCTIONS, descriptions
- `INSTRUCTIONS` gains, after 029's "Activity" paragraph:
  "History. `review_history` lists every rating (from the app or an agent's quiz), dated (UTC), with the card; it
  is never pruned. `struggling_cards` ranks the cards failed (`again`) most. For "what did I study yesterday", pass
  `since`/`until` as the user's local day with its UTC offset. For "why don't I see this card", read its note with
  `find_notes` (each card's `due`, `state`, `next` (spec 028); an open report holds it), then `activity_log`."
  (Drop the `next` mention if 028 hasn't merged when this is built.)
- `activity_log` docstring gains one sentence: "For ratings with card text, or older than 90 days, use
  `review_history`." Nothing else in it changes.
- No other docstring mentions a deleted tool after the change (AC 3). Today only the deleted tools' own docstrings
  do.

### 5. Accounts (030)
Both new tools are plain `deck` reads, so 030a decision 3 applies as for every tool: `deck.review_history` and
`deck.struggling_cards` take `user_id` and filter `ReviewLog.user_id` (and the card join on `Card.user_id`). No
owner cross-user parameter: unlike `activity_log(user=…)` (030a decision 9) a user's review history is theirs only.
Whichever of 031 / 030a merges second adds the `user_id` plumbing and puts both tools in 030a's cross-user matrix
(030a AC 4); the deleted tools leave that matrix. 030a's spec text lists no deleted tool by name (checked), so it
needs no amendment.

### 6. Migration note for agents and clients
Deploying removes 4 tools. MCP clients re-read `tools/list` on reconnect (the server doesn't send
`list_changed`); a call to a removed tool fails with the SDK's unknown-tool error. Mapping (also in
`docs/architecture.md`):

| Removed | Use instead |
|---|---|
| `add_cards(cards)` | `add_notes(notes=[{type: "basic", fields: {front, back}}])`; one card only: add `directions: [{"prompt": ["front"]}]`. Reply: `added`/`skipped` are notes (cards inside) |
| `list_cards(query)` | `find_notes(query)`; cards are in each note's `cards` |
| `update_card(card_id, front, back)` | `update_note(note_id, fields={"front": …, "back": …})` (`note_id` is on every card) |
| `delete_card(card_id)` | `remove_direction(card_id)`; the note's last card: `delete_note(note_id)` |

Client-side leftovers the user may have: permission allowlists (`mcp__la-carte__add_cards`), saved prompts naming
the old tools. Nothing to migrate in data.

## Acceptance criteria
All pytest (`api/tests/test_mcp.py`, new `api/tests/test_history.py`), in-process `mcp.Client(build_mcp(engine))`.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `tools/list` returns exactly the 18 names of decision 1 (set equality) | pytest |
| 2 | `call_tool("add_cards" \| "list_cards" \| "update_card" \| "delete_card", …)` each raise (unknown tool) and change nothing in the database | pytest |
| 3 | No tool description, prompt text (rendered with sample args) or `INSTRUCTIONS` contains `add_cards`, `list_cards`, `update_card` or `delete_card` as a word (`\b…\b`) | pytest |
| 4 | `prompts/list` still returns `quiz_me`, `make_cards`, `add_people`, `handle_reports`, texts unchanged | pytest |
| 5 | REST unchanged: `POST /cards` with one `{front, back}` still creates one note with one card `front → back`; `GET /cards`, `PATCH`/`DELETE /cards/{id}` still pass their existing tests | pytest (existing) |
| 6 | Existing MCP tests that used the deleted tools are rewritten on `add_notes` / `find_notes` / `update_note` / `remove_direction` / `delete_note` (or seed via `deck` directly) and keep covering the same behavior (duplicate skip, `new`/`milestone` reply, review counts in stats, streak survives a deleted card) | pytest |
| 7 | After 3 reviews of card A (MCP `review_card` good, REST `POST /cards/{A}/review` again, MCP easy with `confidence` 0.8), `review_history()` returns 3 entries newest first with `rating`, `confidence` (null where not given), `reviewed_at` UTC and `card.front`/`card.back`/`card.note_id` of A | pytest |
| 8 | Filters: `card_id` returns only that card; `note_id` returns both siblings' reviews and no other note's; `rating="again"` only fails; `since` inclusive, `until` exclusive at an exact `reviewed_at`; naive datetime = UTC; `2026-11-25T00:00:00+01:00` equals `2026-11-24T23:00:00Z`; `since > until` → `[]` | pytest |
| 9 | A card reviewed then removed (`remove_direction`) keeps its entries with `card: null`, visible unfiltered and by `card_id`; unknown ids → `[]` | pytest |
| 10 | `limit` default 100 (seed 101 → 100 newest); `limit=0` and `limit=1001` fail validation | pytest |
| 11 | A review dated 200 days ago is returned (`ReviewLog` isn't pruned; 029's 90-day activity pruning, run first, leaves it) | pytest |
| 12 | `struggling_cards`: cards X (4 reviews, 3 again), Y (2 reviews, 2 again), Z (6 reviews, 2 again), W (0 again), D (again then deleted) → `[X, Y, Z]` with `reviews`/`again`/`last_again_at` correct; W and D absent; `since` after X's fails drops X; `limit=1` → `[X]`; `limit` 0 / 101 fail validation | pytest |
| 13 | Both new tools are read-only: `Card` rows, `ReviewLog` count and `deck_stats` identical before and after calling them | pytest |
| 14 | `INSTRUCTIONS` contains `review_history` and `struggling_cards`; the `activity_log` description contains `review_history` | pytest (substring) |
| 15 | With 030a merged: both tools are in the cross-user matrix (B sees none of A's reviews, by filter or by id), and B's `struggling_cards` never lists A's cards | pytest (030a AC 4, whichever lands second) |
| 16 | `scripts/api-test.sh` green; `scripts/e2e.sh` seeding (`POST /cards`) unaffected | script |

## Screens & states
None. QA's report is pytest output plus a manual MCP check (connect a client to `scripts/api-dev.sh`, list tools,
call `review_history` and `struggling_cards` on a seeded deck); no screenshots.

## TCA shape (iOS)
None. The app doesn't use MCP.

## API / MCP changes
- `mcp_server.py`: delete `add_cards`, `list_cards`, `update_card`, `delete_card` and the `AddCardsReply`,
  `CardCreate`, `CardUpdate` imports there; add the two tools in a `# --- History (spec 031)` section after Activity;
  `INSTRUCTIONS` and `activity_log` docstring per decision 4.
- `deck.py`: `review_history(session, since, until, card_id, note_id, rating, limit) -> list[ReviewEntry]`,
  `struggling_cards(session, since, limit) -> list[StrugglingCard]` (one grouped `select` over `ReviewLog` joined to
  `Card` + `Note`).
- `models.py`: `ReviewEntry`, `StrugglingCard` (BaseModel, read-only); delete `AddCardsReply`.
- No REST endpoint (the app has no history screen; add one only with a feature that needs it).
- `docs/architecture.md` "MCP tools": updated in this change (Cards paragraph, History paragraph, migration table).

### Tool descriptions (contract)
`review_history`: "Every rating the user gave, from the app or an agent's quiz, newest first, never pruned. Each
entry: `card_id`, `reviewed_at` (UTC), `rating` (again = forgot, hard, good, easy), `confidence` (0-1 or null) and
the current `card` (null once deleted). Filters: `since <= reviewed_at < until` (ISO 8601, naive = UTC; for a local
day pass its UTC offset), `card_id`, `note_id` (its current cards), `rating`; `limit` 1-1000 (default 100). If you
get `limit` entries, narrow the window. Read-only."

`struggling_cards`: "Cards the user fails most: per existing card with at least one `again` since `since` (all
history if null), `{card, reviews, again, last_again_at}`, most `again` first, then highest again/reviews. `limit`
1-100 (default 20). Read-only. To help: offer to rephrase (`update_note`), split, or add a direction; change nothing
without the user's OK."

## Accessibility identifiers
None.

## Out of scope
- REST `/cards` removal (old app builds, UI-test stub, e2e seeding use it): backlog if wanted later.
- Any history screen in the app, REST history endpoint, charts, retention curves, per-day aggregates beyond
  `deck_stats.history`.
- Storing lapses or the pre-review FSRS state in responses; changing `ReviewLog`.
- Changing `activity_log` (029) beyond one docstring sentence; adding card text to activity events.
- Owner access to other users' review history.
- Marketing scripts that name the old tools (`docs/marketing/agent-video.md`, `shot-list.md`, `video-tools.md`):
  the marketing agent updates them when it next records (`add_notes` / `find_notes` / `update_note`).

## Changelog
- 2026-11-26: written. Amends 026 (decisions 3, 6; AC 5, 10) and 028 (`list_notes` → `find_notes`).
