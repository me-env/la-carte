# 014 — Notes: one thing you know, recalled from several angles

Status: split — implement from [014a](014a-notes-api.md) (API + MCP), [014b](014b-notes-client.md) (iOS
`APIClient`), [014c](014c-notes-deck-editor.md) (iOS Deck + note editor), [014d](014d-notes-study.md) (iOS Study).
This file holds the shared model and the phase plan. Backlog #27–#30.

## Goal
The user also uses la-carte to remember people "from different angles" (photo → name, photo → name + what they
do, what they do → name) and facts both ways (term → definition, definition → term). Each angle has its own
recall strength, but the angles are linked: fixing a name fixes every angle, and agents editing through MCP see
the link instead of loose, unrelated cards.

## The model (shared vocabulary for every phase)
- **Note** = one thing you know. It has a **type** and named **fields** (strings). The types are a small fixed
  set in code (no user-defined types; add types later in a spec):

  | Type | Fields (in display order) | Required | Duplicate key | Default directions |
  |---|---|---|---|---|
  | `basic` | `front`, `back` | both | `front` | `front → back` only |
  | `person` | `photo` (http(s) URL), `name`, `role` (what they do), `context` (how you know them) | `name` | `name` | none: the creator must list them |

- **Card** = one **direction** over a note's fields: `prompt` fields → `answer` fields (both non-empty, disjoint
  field lists, kept in the type's display order). Each card has its own FSRS state and its own review history.
  A note has at least one card. Two cards of the same note are **siblings**.
- **Shared data lives on the note.** Editing a field updates every card of the note; deleting a note deletes its
  cards (their `ReviewLog` rows stay, spec 012). Scheduling stays per card, server-side.
- **Directions are chosen, never automatic** (user decision). Whoever creates the note (an agent via MCP, or the
  user in the editor) picks its directions. The only default is `basic` with no directions given → exactly one,
  `front → back`. A reverse (`back → front`) or any person angle exists only because someone asked for it, and can
  be added or removed later.
- **Sibling burying** (user decision: 6 hours). After any card of a note is reviewed, its siblings are not served
  for `SIBLING_BURY = 6 h`, and the due queue never holds two cards of the same note at once. Details: 014a.
- **Photos: no storage** (user decision). `photo` is a public http(s) URL saved as text; the app shows it with
  `AsyncImage` (system URL cache); agents and the app both set it. **Privacy:** these are photos of real people.
  The URL lives only on the user's own server, behind the token. Never log photo URLs (API logs, test output),
  never put real people's photos or URLs in fixtures, tests, screenshots, QA reports, commits or marketing; use a
  neutral generated image (014b fixture).

## Compatibility
Existing cards migrate at API startup to `basic` notes with one `front → back` card (same card id, same FSRS
state and history). The `/cards` REST endpoints and the old MCP tools (`add_cards`, `list_cards`, `update_card`,
`delete_card`, `due_cards`, `review_card`) keep working as thin wrappers, and `Card` JSON keeps `front`/`back`
(rendered from the card's prompt/answer fields). So the **shipped app and the widget keep working** between 014a
and 014b–d; a person card just shows its fields as text (photo URL included) until 014d.

## Phases and file overlap (2026-11-21)

| Phase | Owner | Files | Overlaps with in-flight work | Can start |
|---|---|---|---|---|
| **014a** API + MCP | api-engineer | `api/**`, `docs/architecture.md` | **013 step 1** (same `models.py`, `db.py` `_migrate`, `deck.py`, `rest.py`, `mcp_server.py`): run 013 step 1 first (small), then 014a; never both at once | after 013 step 1 merges |
| **014b** iOS data layer | ios-engineer | `APIClient/**`, `APIClientTests/**` | **007 widget** worktree edits `Models.swift`, `LiveAPIClient.swift`, `InMemoryAPIClient.swift`, `DecodingTests.swift` | after 007 merges (contract is fixed by 014a's spec, so it doesn't wait for 014a's code; it needs 014a merged only for its live E2E) |
| **014c** Deck + note editor | ios-engineer | `DeckFeature/**`, `CardEditorFeature/**` → `NoteEditorFeature/**`, `AppFeature/AppFeature.swift`, `Package.swift` | **009a** (Deck) and **009b** (editor) worktrees | after 014b, 009a, 009b merge; design-lead notes first |
| **014d** Study | ios-engineer | `StudyFeature/**` (+ `DesignSystem` photo view if design-lead adds one) | Study lane: **011** in flight, then 009c, 013 step 2 | after 011 and 014b merge; strictly one Study spec at a time (manager picks the order vs 009c / 013 step 2) |
| Design notes for 014c (person editor) + 014d (photo on the card face) | design-lead | the two spec files only | logo round 9 (no file overlap) | **now** |

No widget or stats phase: the widget reads `/stats`, whose `due` already applies burying server-side (014a #11),
and `total` keeps counting cards. Lock Screen widgets (#14) are unaffected.

## Out of scope (all phases)
- User-defined note types or fields; more types (add one per spec later).
- Uploading or storing images; image cropping; contacts import.
- Changing a note's type after creation.
- Card-level tags, decks, or suspending a single card (remove the direction instead).
- Burying by any other rule than "a sibling was reviewed in the last 6 h".
