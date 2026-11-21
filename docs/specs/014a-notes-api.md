# 014a — Notes: API, MCP and migration

Status: ready (starts after 013 step 1 merges: same files)
Owners: api-engineer. No iOS work (the shipped app keeps working through the `/cards` compatibility layer).
Depends on: 012 (merged). Shared model and phase plan: [014](014-notes.md). Backlog #27.
Design reference: none (no UI).

**Parallelism.** Touches `api/src/la_carte_api/{models,db,deck,rest,mcp_server}.py`, `api/tests/`,
`docs/architecture.md`. Same files as **013 step 1** (`ReviewLog.confidence`, `_migrate`, `review_card`): run 013
step 1 first, then this. Parallel to every iOS lane. 014b (iOS client) codes against the contract below and does
not wait for this code, only for its live E2E.

## Goal
The deck stores **notes** (typed, named fields) and **cards** (directions over a note's fields, each with its own
FSRS state). Agents work at note level through MCP and understand that siblings are linked. Existing data
migrates safely at startup; every existing endpoint and tool keeps working.

## Data model (`models.py`)
- `Note` table: `id: UUID` (pk), `type: NoteType` (`basic|person`), `fields: dict[str, str]` (JSON column),
  `created_at`, `updated_at`.
- `Card` table: `id`, `note_id: UUID` (not null, indexed, `FOREIGN KEY → note.id ON DELETE CASCADE`),
  `prompt: list[str]`, `answer: list[str]` (JSON columns), `created_at`, `updated_at`, FSRS columns unchanged.
  The `front` and `back` columns are **removed** (the text lives on the note).
- `ReviewLog`: unchanged (`card_id`, no foreign key; 013's `confidence` if merged).
- `NOTE_TYPES` (plain dict in `models.py` or `deck.py`): per type, ordered field names, required fields, the
  duplicate key field, and the default directions (`basic`: `[front → back]`; `person`: none). See 014's table.

### Validation (one place in `deck.py`; REST → 422 `{"detail": "<message>"}`, MCP → `ToolError(<message>)`)
Messages are written for an LLM reader and name the offending field or direction.
1. Field values are trimmed; an empty value means "absent" (removed from `fields`).
2. Unknown field name for the type → error listing the type's fields.
3. A required field missing → error.
4. `photo`, if present, must be an `http`/`https` URL with a host → error otherwise.
5. Each direction: `prompt` and `answer` non-empty, known fields, disjoint; stored in the type's field order
   (so `["name","photo"]` ≡ `["photo","name"]`); no two cards of a note with the same direction.
6. Every field used by a direction must be present in the note (e.g. no `photo → name` without a photo). Clearing a
   field that a direction uses → error "remove the direction first".
7. A note always has ≥ 1 direction. `person` with no `directions` given → error "choose directions: e.g.
   photo → name, role → name". `basic` with none given → `front → back`.

## Sibling burying (`deck.py`)
`SIBLING_BURY = timedelta(hours=6)` (named constant, user decision). One function decides what is servable now and
is used by both `due_cards` and `stats`:
- A card is **buried** if another card of the same note has a `ReviewLog` row with `reviewed_at > now − 6 h`. The
  reviewed card itself is not buried by its own review (a relearning step due in 10 min is still served).
- The servable queue is: due cards (`due <= now`), not buried, most overdue first, **at most one card per note**
  (the most overdue wins). So the app's local queue never holds two siblings.
- `stats.due` = the size of that queue (the widget and Study's counter agree with what can be studied now).
  `stats.next_due` = the earliest time after now at which a card not servable now becomes servable: its `due` if in
  the future, or `latest sibling review + 6 h` if it is due but buried; `null` if none. `total` and `new` keep
  counting cards. `reviewed_today` and `streak` are unchanged.

## Startup migration (`db._migrate`, after 012's and 013's steps)
Runs when `PRAGMA table_info(card)` still has a `front` column; same safety pattern as 012:
1. File DB: `VACUUM INTO <db>.pre-014-<UTC timestamp>.bak` first.
2. `PRAGMA foreign_keys=OFF`, `BEGIN IMMEDIATE`, re-check the condition under the lock.
3. `INSERT INTO note (id, type, fields, created_at, updated_at) SELECT id, 'basic', json_object('front', front,
   'back', back), created_at, updated_at FROM card` — **the migrated note reuses its card's id** (deterministic,
   no mapping table).
4. Rebuild `card` from the model's DDL (`card_new`, `INSERT … SELECT id, id AS note_id, '["front"]',
   '["back"]', …`, drop, rename, recreate indexes).
5. `COMMIT` (any failure → `ROLLBACK`, old tables intact), `PRAGMA foreign_keys=ON`.
Card ids, FSRS state and `ReviewLog` rows are untouched, so stats, streak and the widget are identical before and
after.

## REST contract (new)

| Method | Path | Body / query | Returns |
|---|---|---|---|
| GET | `/notes` | `?query=&type=&limit=` (limit ≤ 500, default 100) | `[Note]` newest first; `query` = trimmed, casefolded substring of any field except `photo` |
| POST | `/notes` | `NoteCreate` | `Note` (201). Always adds (no duplicate check, like `POST /cards`) |
| GET | `/notes/{id}` | — | `Note` / 404 |
| PATCH | `/notes/{id}` | `NoteUpdate` | `Note`. `fields`: merged key by key, `""` clears. `directions`: **the full desired set**: kept directions keep their card (id, FSRS state); new ones become new cards due now; missing ones are deleted (history kept) |
| DELETE | `/notes/{id}` | — | 204; the note and all its cards are gone (review history kept) |

```json
// NoteCreate
{"type": "person",
 "fields": {"photo": "https://example.org/p/42.jpg", "name": "Ada Example", "role": "runs the bakery"},
 "directions": [{"prompt": ["photo"], "answer": ["name"]}, {"prompt": ["role"], "answer": ["name"]}]}
// NoteUpdate (both optional)
{"fields": {"role": "runs the bakery and the café"}, "directions": [{"prompt": ["photo"], "answer": ["name", "role"]}]}
// Note
{"id": "…", "type": "person", "fields": {"photo": "…", "name": "Ada Example", "role": "runs the bakery"},
 "cards": [{"id": "…", "prompt": ["photo"], "answer": ["name"], "state": "new", "due": "…", "last_review": null}],
 "created_at": "…", "updated_at": "…"}
```

### `/cards` (compatibility; paths unchanged)
`Card` gains fields; old ones keep their meaning:
```json
{"id": "…", "note_id": "…", "type": "person", "prompt": ["photo"], "answer": ["name", "role"],
 "fields": {"photo": "…", "name": "Ada Example", "role": "runs the bakery"},
 "front": "https://example.org/p/42.jpg", "back": "Ada Example\nruns the bakery",
 "state": "new", "due": "…", "last_review": null, "created_at": "…", "updated_at": "…"}
```
- `fields` = the whole note's fields; `front` / `back` = the prompt / answer field values joined by `"\n"`
  (for old clients; new clients render from `prompt`, `answer`, `fields`).
- `GET /cards?query=`: cards whose note matches (same matching as `/notes`). `GET /cards/due`: the servable queue.
- `POST /cards {front, back}` → a `basic` note with `front → back`; returns that card.
- `PATCH /cards/{id} {front?, back?}` edits **what this card shows**: `front` → its single prompt field, `back` → its
  single answer field (so a `back → front` card's `front` edits the note's `back`). If the card's prompt or answer
  has more than one field → 422 "use PATCH /notes/{note_id}". Siblings see the change.
- `DELETE /cards/{id}` removes that direction; if it was the note's last card, the note is deleted too.
- `POST /cards/{id}/review`, `GET /stats` unchanged in shape (`due`, `next_due` per burying above).

## MCP
New tools (docstrings = agent docs; each says what it does to siblings):
- `add_notes(notes: list[NoteCreate], allow_duplicates=False) -> {added: [Note], skipped: [Note]}`. A note whose
  type and duplicate key (`basic.front`, `person.name`; casefolded, trimmed) match an existing note or an earlier
  one in the call is skipped; the existing note is returned in `skipped`. (Batch form of the agreed `add_note`:
  "add these 30 words" is one call.)
- `find_notes(query=None, type=None, limit=50) -> [Note]`: check before adding; returns each note's cards.
- `update_note(note_id, fields: dict[str, str]) -> Note`: edits fields for every card of the note; `""` clears.
- `add_direction(note_id, prompt: list[str], answer: list[str]) -> Note`: a new card, due now.
- `remove_direction(card_id) -> Note`: deletes that card (history kept); refuses the note's last card ("use
  `delete_note`").
- `delete_note(note_id) -> str`.

Kept, as thin wrappers with the `/cards` semantics above: `add_cards` (creates `basic` notes `front → back`,
duplicate check on `basic` notes' `front`, same `{added, skipped}` of `Card`), `list_cards`, `update_card`,
`delete_card`, `due_cards` (servable queue), `review_card`, `deck_stats`. Their docstrings start with "Prefer the
note tools" where a note tool exists (`add_cards`, `list_cards`, `update_card`, `delete_card`).

### Server `INSTRUCTIONS` (replace; engineer may polish wording, not meaning)
```
la-carte is the user's single flashcard deck (spaced repetition, FSRS).

Notes and cards. A note is one thing the user knows, with named fields. A card is one direction over
those fields (prompt fields -> answer fields) and has its own schedule. Cards of the same note are
siblings: editing a field changes every sibling; deleting the note deletes them all.
Note types:
- basic: front, back (both required). Default direction: front -> back.
- person: photo (public http(s) URL), name (required), role (what they do), context (how the user
  knows them). No default: list the directions.

Edit the note, not loose cards: to fix a typo use `update_note`; to quiz another angle use
`add_direction`, never a second note with the same content. Check `find_notes` before adding;
`add_notes` skips a note whose key (basic: front, person: name) already exists and returns it.

Choose directions deliberately, never "all of them". Add back -> front only when recalling it that
way is useful to the user (e.g. vocabulary they must produce, not just recognize). For a person, pick
the angles the user wants to recall (e.g. photo -> name, role -> name). Each extra direction is extra
daily work.

Cards stay minimalist: front = a word or short question, back = the shortest answer, one fact per note.
Photos are of real people: only use URLs the user gave you or asked you to use; never repeat them
outside this deck.

Quiz: `due_cards` (siblings of a just-reviewed card are held back for 6 hours), then `review_card`.
Ready-made prompts: `quiz_me`, `make_cards`.
```
- `quiz_me`: show only the card's prompt fields (a `photo` is a URL: show it as an image or link), wait, then the
  answer fields. `make_cards`: check with `find_notes`, add with one `add_notes` call of `basic` notes, directions
  per the rule above.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `POST /notes` with the person example returns 201 and a `Note` with 2 cards (`["photo"]→["name"]`, `["role"]→["name"]`), both `new`, due now | pytest (REST) |
| 2 | `POST /notes {"type":"basic","fields":{"front":"chat","back":"cat"}}` (no `directions`) creates exactly one card `front → back`; no reverse card exists | pytest |
| 3 | `person` without `directions` → 422 naming the missing directions; nothing is written | pytest |
| 4 | Validation 1–7 each produce a 422 with a message naming the field/direction (one test per rule), and the same via MCP as a `ToolError` | pytest (REST + MCP) |
| 5 | `PATCH /notes/{id}` with `fields.name` changes `fields` on every sibling's `Card` (`GET /cards/{id}` of both) and keeps their FSRS state | pytest |
| 6 | `PATCH /notes/{id}` with `directions` = {kept A, new C}, dropping B: A keeps its id and `due`; C is new and due now; B returns 404; B's `ReviewLog` rows still exist | pytest |
| 7 | `DELETE /notes/{id}` → 204; its cards are gone from `/cards` and `/cards/due`; `streak`/`reviewed_today` unchanged | pytest |
| 8 | Burying: note with cards A, B both due. `GET /cards/due` returns only A (most overdue, one per note). Review A (`good`): B is not returned for 6 h (test at now+5h59 → absent, now+6h01 → present) | pytest (deck, injected `now`) |
| 9 | A relearning card reviewed `again` is served again when due, even though it was reviewed < 6 h ago, while its sibling stays buried | pytest |
| 10 | Unrelated notes are never affected by burying; a note with one card behaves exactly as before | pytest |
| 11 | `GET /stats`: `due` equals the length of `/cards/due?limit=500`; with only a buried card left, `due` is 0 and `next_due` = sibling review time + 6 h | pytest |
| 12 | Legacy: `POST /cards`, `GET /cards?query=`, `PATCH /cards/{id}`, `DELETE /cards/{id}`, review and stats keep their old behavior on `basic` `front → back` notes (existing REST tests pass unchanged apart from added keys) | pytest |
| 13 | Legacy `PATCH /cards/{id} {"front":"x"}` on a `back → front` card sets the note's `back` to "x"; on a card with a multi-field side → 422 | pytest |
| 14 | Legacy `DELETE /cards/{id}` of a note's last card deletes the note (`GET /notes/{note_id}` → 404); of a non-last card keeps the note | pytest |
| 15 | MCP: `add_notes` adds, skips a duplicate key (case/whitespace-insensitive, also within one call) and returns the existing note in `skipped`; `allow_duplicates=true` adds it; a `person` and a `basic` with the same key text don't collide | pytest (MCP) |
| 16 | MCP: `find_notes`, `update_note`, `add_direction` (duplicate direction → error), `remove_direction` (last card → error), `delete_note` behave as REST | pytest (MCP) |
| 17 | MCP: old tools (`add_cards`, `list_cards`, `update_card`, `delete_card`, `due_cards`, `review_card`, `deck_stats`) pass their existing tests | pytest (MCP) |
| 18 | `INSTRUCTIONS` contain the notes/cards explanation, both types, "Choose directions deliberately" and the 6-hour burying; `quiz_me` / `make_cards` reference `prompt`/`answer` and `find_notes`/`add_notes` | pytest (substring) + review |
| 19 | **Migration**: an old-schema file DB (cards with front/back, review logs) → after `make_engine`: one `basic` note per card with `note.id == card.id` and `fields == {front, back}`; each card has `prompt ["front"]`, `answer ["back"]` and identical FSRS columns; `card` has no `front`/`back` columns; `PRAGMA foreign_key_list(card)` points to `note`; review logs identical; a `.pre-014-*.bak` file exists | pytest (`tmp_path`) |
| 20 | Migration is idempotent (second start changes nothing, no new backup) and a fresh DB skips it; a failure mid-rebuild leaves the old tables intact | pytest + review |
| 21 | No photo URL appears in the API's log output for any request (no request-body logging added; validation messages name the field, not the value) | review |
| 22 | `docs/architecture.md` documents Note/Card, the new REST rows, the new MCP tools, burying, and the migration | review |

## TCA shape (iOS)
None (014b–d).

## Accessibility identifiers
None.

## Out of scope
- Bulk REST for notes; changing a note's type; fuzzy duplicates; checking that a photo URL actually loads.
- Tuning `SIBLING_BURY` per type or via settings.
- Removing the legacy tools/endpoints (a later spec, once the app no longer uses them).
