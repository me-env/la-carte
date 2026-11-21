# 014b — Notes: iOS data layer (`APIClient`)

Status: ready (starts when 007's worktree merges: same `APIClient` files)
Owners: ios-engineer. No UI change.
Depends on: 014a's **contract** (fixed in [014a](014a-notes-api.md); its code is needed only for the live E2E).
Shared model: [014](014-notes.md). Backlog #28.
Design reference: none.

**Parallelism.** Touches only `ios/LaCarteKit/Sources/APIClient/**` and `Tests/APIClientTests/**`, plus the
runtime-config table in `docs/architecture.md` and `docs/testing.md` (new mock). Conflicts with the **007 widget**
worktree (`Models.swift`, `LiveAPIClient.swift`, `InMemoryAPIClient.swift`, `DecodingTests.swift`): start after
007 merges. Runs in parallel to 014a, 011 (Study) and 009a/009b. Unblocks 014c and 014d.

## Goal
The app can read and write notes and knows each card's direction and fields, so 014c (deck + editor) and 014d
(study) only have UI work left. Nothing on screen changes yet.

## Models (`Models.swift`)
- `NoteType: String, Codable, CaseIterable` = `basic`, `person`, with `fields: [String]` in display order
  (`["front","back"]`, `["photo","name","role","context"]`). Mirrors the API's fixed set; no other logic.
- `Direction: Codable, Hashable { prompt: [String]; answer: [String] }`.
- `Note: Codable, Equatable, Identifiable { id, type, fields: [String: String], cards: [Note.Card], createdAt,
  updatedAt }`, `Note.Card { id, prompt, answer, state, due, lastReview }` (+ `var direction: Direction`).
- `NoteDraft: Encodable, Equatable { type, fields, directions: [Direction] }` (the editor's save payload).
- `Card` gains `noteId: UUID`, `type: NoteType`, `prompt: [String]`, `answer: [String]`, `fields: [String: String]`.
  `front` / `back` stay (010's inline edit still uses them). **Decoding tolerates a pre-014a server**: missing
  keys default to `noteId = id`, `type = .basic`, `prompt = ["front"]`, `answer = ["back"]`,
  `fields = ["front": front, "back": back]`.

## APIClient
New endpoints (old ones unchanged; 014c removes the ones it stops using):
| Endpoint | Request |
|---|---|
| `notes: (_ query: String?) async throws -> [Note]` | `GET /notes?limit=500&query=` |
| `addNote: (_ draft: NoteDraft) async throws -> Note` | `POST /notes` |
| `updateNote: (_ id: Note.ID, _ draft: NoteDraft) async throws -> Note` | `PATCH /notes/{id}` with `{fields, directions}`; **every** field of the type is sent, absent ones as `""`, so a cleared field is cleared on the server |
| `deleteNote: (_ id: Note.ID) async throws -> Void` | `DELETE /notes/{id}` |

`HTTP.send`/`data` take an `Encodable` body instead of `[String: String]` (existing calls keep their JSON).

## In-memory client and fixtures
- The in-memory deck stores **notes**; cards are derived. `cards`, `addCard`, `updateCard`, `deleteCard`, `review`,
  `stats` keep their current behavior on `basic` notes (legacy semantics of 014a: `updateCard` edits the shown
  sides, deleting a note's last card deletes the note).
- `dueCards`: due, at most one card per note, and a card is skipped if a sibling's `lastReview` is within 6 h of
  `now` (same rule as the API, `siblingBury = 6 * 3600` constant). `stats.due` = that count.
- `LA_CARTE_API=mock` is **unchanged**: the 3 fixture cards become 3 `basic` notes (`note.id == card.id`, as the
  migration does), so every existing screenshot and UI test stays valid.
- New `LA_CARTE_API=mock-notes` = those 3 notes, plus `"la carte"` gets a second direction `back → front`, plus one
  person note: name "Ada Example", role "runs the bakery", context "met at the climbing gym", photo = a **neutral
  generated image** (abstract shape, no face, no real person) as a `data:image/png;base64,…` URL constant, cards
  `photo → name` and `role → name`. Stable ids `…0011`–`…0014`, all due at the fixture date, person cards first.
  (A `data:` URL is mock-only; the API accepts only http(s). It keeps UI tests offline and deterministic.)

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `Note` decodes from 014a's `Note` JSON example (snake_case keys, fields dictionary, nested cards) | unit (`DecodingTests`) |
| 2 | `Card` decodes 014a's new `Card` JSON, **and** the pre-014a JSON with the defaults above | unit |
| 3 | `addNote` / `updateNote` encode `{"type"?, "fields", "directions"}` exactly as 014a (`updateNote` has no `type`, has all the type's fields with `""` for absent ones) | unit (request capture or encoder test) |
| 4 | `notes(query)` builds `GET /notes?limit=500&query=…`; `deleteNote` builds `DELETE /notes/{id}` | unit |
| 5 | In-memory `dueCards` returns at most one card per note; after `review` of one sibling, the other is not returned at `now` | unit (`InMemoryAPIClientTests`) |
| 6 | `LA_CARTE_API=mock` yields the same 3 cards (ids, text, order) as before this spec | unit |
| 7 | `mock-notes` yields 4 notes / 6 cards with the ids above; the photo field is a `data:image/png` URL | unit |
| 8 | No real person's photo or URL exists anywhere in the repo's fixtures or tests | review |
| 9 | `docs/architecture.md` runtime-config table and `docs/testing.md` list `LA_CARTE_API=mock-notes` | review |
| 10 | `scripts/ios-test.sh` green; existing UI tests (`scripts/ios-ui-test.sh`) pass unchanged | unit + UI (QA re-run, no new screenshots) |

## TCA shape (iOS)
No feature changes. Clients don't import ComposableArchitecture (rule unchanged).

## API / MCP changes
None (consumes 014a).

## Accessibility identifiers
None.

## Screenshots
None new (QA re-runs the existing suite to prove nothing moved).

## Out of scope
- Any view; removing old endpoints (014c); image prefetching or a custom image cache.
