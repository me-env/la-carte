# 026 — Basic notes default to both directions

Status: ready
Owners: api-engineer → code-reviewer → qa-validator (pytest-only validation: no UI, no screenshots)
Depends on: nothing (014a notes API merged).
Amends: [014a](014a-notes-api.md) AC 2 and its `INSTRUCTIONS` / `make_cards` / `add_notes` wording.
Design reference: none (no screen).

## Goal
When an agent adds `basic` notes without saying which directions, each note gets **both** cards,
`front → back` and `back → front`: learning both ways is the common case (user request). It is a real
server default, so an agent that never reads the guidance still gets both. The agent picks one direction
explicitly only when the reverse isn't a meaningful question ("Capital of France?" → "Paris").

## User stories
- As the user, I ask an agent to "add these 20 words" and can recall each word both ways without
  asking for it.
- As the user, a one-way fact ("Capital of France?") still makes a single card, because the agent
  passes that direction explicitly.

## Decisions
1. **One default, in `deck.py`.** `NOTE_TYPES[basic].default_directions` becomes
   `(front → back, back → front)`. Every path that creates a basic note **without** `directions` shares it:
   MCP `add_notes` and REST `POST /notes`. No second default in the MCP layer.
2. **The iOS app is not affected.** `NoteEditorFeature` always sends explicit `directions` (its own toggles,
   new basic = `front-back` on, spec 014c AC 10), so the server default never applies to it. No contract change:
   `NoteCreate` keeps the same shape (`directions` optional); only the meaning of "omitted" changes for basic.
   No `APIClient` / `DecodingTests` change. Whether the editor should also pre-check `back-front` is a separate
   UI decision: the user said yes, see [027](027-editor-both-directions.md).
3. **Legacy `add_cards` (MCP) and `POST /cards` stay one card `front → back`.** They are the card-level
   compatibility layer: one `CardCreate` in, one `Card` out (`added: [Card]`), used by REST `POST /cards`, the
   e2e/UI-test seeding and many pytest fixtures. Giving them two cards would break that 1:1 shape. `deck.add_cards`
   therefore passes `directions=[front → back]` explicitly instead of relying on the default. Its MCP docstring
   says it makes one card per item and that `add_notes` makes both directions by default.
4. **person notes: unchanged.** No default; `directions` stay required and chosen explicitly (ask the user
   if they haven't said).
5. **Existing notes: no backfill.** Notes created before this change keep their cards; nothing adds reverse
   cards to them. An agent can still `add_direction` on request.
6. **Wording, said once per surface:** `INSTRUCTIONS`, the `make_cards` prompt, the `add_notes` docstring
   and the `NoteCreate.directions` field description all state the same rule:
   - basic without `directions` = both cards (front → back and back → front);
   - pass `directions` with one direction only when the reverse isn't a meaningful question
     (e.g. "Capital of France?" → "Paris");
   - person: always pick directions explicitly.
   The current lines "Choose directions deliberately, never "all of them"", "Default direction:
   front -> back", "no `directions` = front -> back only", "Leave `directions` out (front -> back) unless …"
   and "never add every direction by default" are removed.

Suggested `INSTRUCTIONS` lines (engineer may tighten, meaning must stay):
```
- basic: front, back (both required). No `directions` = both cards: front -> back and back -> front.
  Pass one direction only when the reverse isn't a meaningful question (e.g. "Capital of France?" -> "Paris").
- person: … No default: pick directions deliberately (ask the user if they haven't said).
```
The paragraph starting "Choose directions deliberately, never "all of them"" is replaced by the person line
above plus "Each direction is one more card to review."

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | MCP `add_notes` with one basic note `{"front":"chat","back":"cat"}` and no `directions` returns a note with exactly 2 cards: `["front"]→["back"]` and `["back"]→["front"]`, both `new` and due now | pytest (MCP) |
| 2 | REST `POST /notes {"type":"basic","fields":{"front":"chat","back":"cat"}}` (no `directions`) returns 201 and a `Note` with the same 2 cards (replaces 014a AC 2) | pytest (REST) |
| 3 | MCP `add_notes` with a basic note and `directions: [{"prompt":["front"],"answer":["back"]}]` creates exactly 1 card `front → back`; no reverse card exists | pytest (MCP) |
| 4 | MCP `add_notes` with a person note and no `directions` still fails with a `ToolError` naming the allowed directions; nothing is written (REST: 422) | pytest (MCP + REST) |
| 5 | MCP `add_cards` with one `{"front":"chat","back":"cat"}` and REST `POST /cards` each create a note with exactly 1 card `front → back` | pytest (MCP + REST) |
| 6 | `add_notes` reply `new` counts both cards of each default basic note (one basic note into an empty deck → `new == 2`) | pytest (MCP) |
| 7 | A note created with 1 card before the change keeps 1 card after `update_note` with only `fields` (no directions re-derived, no backfill) | pytest |
| 8 | `INSTRUCTIONS` contain "back -> front" in the basic line and "Capital of France"; do **not** contain "never \"all of them\"" or "Default direction: front -> back" | pytest (substring) |
| 9 | The `make_cards` prompt text does **not** contain "never add every direction by default" and contains "Capital of France"; the `add_notes` tool description contains "back -> front" and does not contain "front -> back only" | pytest (substring) |
| 10 | The `add_cards` tool description says it makes one card `front -> back` per item and points to `add_notes` | pytest (substring) |
| 11 | `NoteCreate.directions` field description (OpenAPI `/openapi.json`) says basic defaults to both directions | pytest |
| 12 | `scripts/api-test.sh` passes; existing tests that asserted the old wording (`test_mcp.py` "Choose directions deliberately") or 1 card from a basic `add_notes`/`POST /notes` without directions are updated to the new rule, not deleted | pytest + review |

## Screens & states
None. No UI change; no screenshots.

## TCA shape (iOS)
None (decision 2).

## API / MCP changes
- `deck.py`: `NOTE_TYPES[basic].default_directions = ((("front",), ("back",)), (("back",), ("front",)))`;
  `directions_hint` unchanged. `add_cards` builds `NoteCreate(..., directions=[Direction(prompt=["front"],
  answer=["back"])])`; its docstring stays "front -> back".
- `models.py`: `NoteCreate.directions` description: "Omit for basic (both: front -> back and back -> front);
  required for person: …".
- `mcp_server.py`: `INSTRUCTIONS`, `MAKE_CARDS` prompt, `add_notes` and `add_cards` docstrings per decision 6
  and AC 8–10.
- REST: no new endpoint; `POST /notes` behaviour for basic without `directions` changes (decision 1).
- Docs: 014a AC 2 gets an "*Amended by 026*" note (done in this change).

## Accessibility identifiers
None.

## Out of scope
- Backfilling reverse cards onto existing notes (decision 5).
- The iOS editor's default toggles ([027](027-editor-both-directions.md)).
- person defaults.
- Changing `add_cards` / `POST /cards` to two cards (decision 3).
