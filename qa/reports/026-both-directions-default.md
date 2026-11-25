# QA: 026 Basic notes default to both directions

Verdict: PASS
Date: 2026-11-25 · Implementation: commit 189f62d (API/MCP only, no UI, no screenshots)
Commands: `scripts/api-test.sh` (PASS: ruff clean, 260 passed) · live walk over real MCP streamable HTTP
(mcp 2.3.0 client) + REST against a fresh API (`uvicorn … --port 8726`, scratch SQLite DB, bearer token),
started empty and stopped afterwards.

## Acceptance criteria
| # | Result | Evidence (live walk unless noted) |
|---|---|---|
| 1 | PASS | `add_notes [{"type":"basic","fields":{"front":"chat","back":"cat"}}]` → 1 note, 2 cards: `["front"]→["back"]` and `["back"]→["front"]`, both `state: new`, `due` = creation time |
| 2 | PASS | `POST /notes {"type":"basic","fields":{"front":"oiseau","back":"bird"}}` → 201, Note with the same 2 cards |
| 3 | PASS | `add_notes` "Capital of France?"/"Paris" with `directions:[{"prompt":["front"],"answer":["back"]}]` → exactly 1 card front→back, no reverse |
| 4 | PASS | MCP person note without directions → `is_error: true`, "Choose directions for this person note (photo -> name + description, name -> photo + description, description -> name + photo) …"; REST `POST /notes` person → 422 same message; afterwards `GET /notes` holds only basic notes (nothing written) |
| 5 | PASS | MCP `add_cards [{"front":"chien","back":"dog"}]` → 1 Card front→back; REST `POST /cards` poisson/fish → 201, its note has 1 card (`GET /notes`) |
| 6 | PASS | first `add_notes` into the empty deck returned `new: 2` (then 3, 4 as later items were added) |
| 7 | PASS | `update_note` (fields only) on the 1-card "Capital of France?" note → still 1 card, field updated; plus pytest `test_both_directions.py` |
| 8 | PASS | live `initialize` instructions: basic line "No `directions` = both cards: front -> back and back -> front", contains "Capital of France"; none of `never "all of them"`, "Default direction: front -> back" |
| 9 | PASS | `make_cards` prompt: "Leave `directions` out to get both cards (front -> back and back -> front); pass one direction only when the reverse isn't a meaningful question (e.g. "Capital of France?" -> "Paris")"; no "never add every direction by default". `add_notes` description contains "back -> front", not "front -> back only" |
| 10 | PASS | `add_cards` description: "Prefer the note tools (`add_notes`, which makes both directions by default). Adds basic notes, one card front -> back per item" |
| 11 | PASS | `/openapi.json` `NoteCreate.directions`: "Omit for basic (both: front -> back and back -> front; pass one only when the reverse isn't a meaningful question); required for person: …" |
| 12 | PASS | `scripts/api-test.sh` green; `test_mcp.py` wording asserts and `test_notes.py::test_basic_note_without_directions_gets_both_directions` were updated (2 cards), not deleted |

## Wording coherence
INSTRUCTIONS, `make_cards`, `add_notes`, `add_cards` and `NoteCreate.directions` state the same rule
(basic default = both; one direction only when the reverse isn't meaningful; person always explicit,
"Each direction is one more card to review"). No leftover contradictory line found.

## Bugs
None.
