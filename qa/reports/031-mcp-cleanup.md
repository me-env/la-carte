# QA: 031 MCP cleanup (drop the legacy card tools, add review history)

Verdict: PASS
Date: 2026-11-26 · branch `031-mcp-cleanup` @ `2c9a49a` · API/MCP only (no simulator, no screenshots)
Runs: fresh dev API from the branch (`uvicorn la_carte_api.app:create_app --factory`, port 18931, scratch SQLite
database, no token), driven over HTTP with raw MCP JSON-RPC (`initialize` → `tools/list` / `prompts/list` /
`prompts/get` / `tools/call`, streamable HTTP on `/mcp`) plus REST calls, as an agent would.
Commands: `scripts/api-test.sh` (✅ ruff + format + 305 passed), manual MCP check (✅), `scripts/e2e.sh` not run
(simulators unavailable today; the only e2e dependency, `POST /cards`, checked over HTTP, AC 16).

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `tools/list` → 18 tools, set-equal to decision 1: `activity_log, add_direction, add_notes, close_feedback, deck_stats, delete_note, due_cards, find_notes, list_feedback, list_reports, new_card_milestone, remove_direction, review_card, review_history, send_feedback, struggling_cards, update_note, update_report` (missing ∅, extra ∅) |
| 2 | PASS | `tools/call` `add_cards` / `list_cards` / `update_card` / `delete_card` → `isError: true`, `"Unknown tool: <name>"` each; database after the four calls: 0 notes, 0 cards (empty before). pytest `test_removed_card_tools_are_unknown_and_change_nothing` |
| 3 | PASS | Regex `\b(add_cards\|list_cards\|update_card\|delete_card)\b` over every tool description + input/output schema, `initialize.instructions`, and all 4 prompts rendered via `prompts/get` with sample args: 0 matches. pytest `test_no_text_names_a_removed_tool` |
| 4 | PASS | `prompts/list` → `add_people, handle_reports, make_cards, quiz_me`. `git diff main` hunks in `mcp_server.py` all end before the prompt section (prompt code untouched); `quiz_me(limit=5)` renders "Call `due_cards` with limit 5 …" |
| 5 | PASS | `POST /cards {front: rest-front, back: rest-back}` → 201, one note with one card `prompt [front] → answer [back]` (via `find_notes`); `PATCH /cards/{id}` 200, `GET /cards` 200, `DELETE /cards/{id}` 204; existing REST tests green |
| 6 | PASS | `test_mcp.py` rewritten: `test_add_notes_skips_duplicates_unless_allowed`, `test_deck_stats_streak_survives_delete_note`, etc.; 305 passed |
| 7 | PASS | Card A1 (`chat → cat`): MCP `review_card good`, REST `POST /cards/{A1}/review again`, MCP `easy` + `confidence 0.8` → `review_history()` = `[easy 0.8 @22:13:45.807065Z, again null @…797564Z, good null @…784208Z]`, each with `card.front "chat"`, `card.back "cat"`, `card.note_id` = A's note, `reviewed_at` suffixed `Z` |
| 8 | PASS | `card_id=A1` → only A1's 3; `note_id=A` → A2 good + A1's 3, no note B entry; `rating=again` → only fails; `card_id=A1 & note_id=B` → `[]` (AND). Exact timestamp T of A1's `again`: `since=T` → `[easy, again]` (inclusive), `until=T` → `[good]` (exclusive); naive `T` (no Z) → same as Z; `2026-11-26T23:13:45.797564+01:00` → same as `…22:13:45.797564Z` for both `since` and `until`; `since 2026-11-27Z > until 2026-11-26Z` → `[]` |
| 9 | PASS | E1 rated `again`, then `remove_direction(E1)`: `review_history(card_id=E1)` and unfiltered both show `{rating: again, card: null}`; `note_id=E` (current cards only) → `[]`; random UUID as `card_id` / `note_id` → `[]` (no error) |
| 10 | PASS | 101 reviews → default returns 100, equal to the newest 100 of `limit=1000` (oldest dropped); `limit=0` → "Input should be greater than or equal to 1", `limit=1001` → "less than or equal to 1000" |
| 11 | PASS | A `ReviewLog` row dated 200 days ago (inserted in the scratch DB, `2026-05-10T22:14:01Z`) is returned by `review_history(card_id=B)`; still there after a server restart (`prune_activity` runs at startup) |
| 12 | PASS | X (again×3, good), Y (again×2), Z (again, good, again, good×3), W (good×2), D (again, then `delete_note`) → `struggling_cards()` = `X {reviews 4, again 3, last_again_at = X's 3rd again}`, `Y {2, 2}`, `Z {6, 2}`, then A1 `{3, 1}` (its REST `again` above, correct for this deck); W and D absent. `since` = Y's first fail (after all of X's reviews) → `[Y, Z]`; `since` = X's 2nd fail → X `{reviews 3, again 2}` (counts are in-window); `limit=1` → `[X]`; `limit` 0 / 101 → validation errors, 100 OK |
| 13 | PASS | Before/after 3 rounds of `review_history` + `struggling_cards` calls: `GET /cards` JSON identical, `ReviewLog` count 22 → 22, `deck_stats` identical |
| 14 | PASS | `initialize.instructions` contains `review_history` and `struggling_cards` (History paragraph present, text as decision 4); `activity_log` description ends "For ratings with card text, or older than 90 days, use `review_history`." |
| 15 | N/A | 030a not merged on this branch; whichever lands second adds the cross-user matrix (spec decision 5) |
| 16 | PASS | `scripts/api-test.sh` green (ruff, format, 305 passed). e2e seeding = `POST /cards`, checked over HTTP (AC 5); `scripts/e2e.sh` itself not run (no simulators today) |

Also checked: `review_history` entries' `card` has exactly the `due_cards` `CardRead` keys (`answer, back,
created_at, due, fields, front, id, last_review, note_id, prompt, state, type, updated_at`); `stability_before` /
`last_review_before` not exposed; bad `rating` (`"forgot"`) → enum validation error.

## Visual review
Not applicable (no screen).

## Observations (non-blocking)
1. INSTRUCTIONS say "read its note with `find_notes` (each card's `due`, `state`, `next` (spec 028) …)". `next`
   is on the **note** (`{card_id, ready_at}`), not on each card. The wording is the spec's verbatim text and an
   agent finds `next` one level up, so not a defect; the architect may want "each card's `due`, `state`, the
   note's `next`".

## Bugs
None.
