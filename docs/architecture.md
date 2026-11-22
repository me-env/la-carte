# Architecture

```
 agents (Claude, …) ──MCP (streamable HTTP, /mcp)──┐
                                                   ▼
 iOS app ──REST (JSON)──────────────────────► FastAPI app ──► deck.py ──► SQLite
                                               (api/)        (FSRS)
```

**The API is the single source of truth.** Scheduling (FSRS) runs server-side only, so the app,
agents and any future client always agree on what is due. The app is a client; it holds no
scheduling logic.

## API (`api/src/la_carte_api/`)

| File | Role |
|---|---|
| `models.py` | SQLModel tables (`Note`, `Card`, `ReviewLog`, `Report`) + public pydantic schemas (`NoteRead`, `CardRead`, `NoteCreate`, …) |
| `deck.py` | **All behavior.** Plain functions taking a `Session`, returning the read schemas. Testable without HTTP. |
| `rest.py` | FastAPI routes, thin wrappers over `deck` (consumed by iOS) |
| `mcp_server.py` | MCP tools, thin wrappers over `deck` (consumed by agents) |
| `app.py` | Assembly: engine, routes, MCP mount at `/mcp`, bearer-token middleware |
| `config.py` | `LA_CARTE_*` env settings |

Rules:
- New behavior goes in `deck.py` first, then exposed via REST **and** MCP when both make sense.
- REST and MCP return the same schemas (`NoteRead`, `CardRead`, `DeckStats`).
- Times are UTC everywhere; `now` is injectable in `deck` functions for tests.
- No login. Optional single bearer token (`LA_CARTE_API_TOKEN`) protects REST + MCP when deployed.
- MCP tool docstrings are the agent-facing docs: write them for an LLM reader (what, when, effects).
- Schema changes on existing tables go in `db._migrate`: idempotent, checked with `PRAGMA`, run at startup
  **before** `create_all` (so a backup is an exact copy of the old file; a missing table = fresh database, skipped).
  Plain SQL, no migration framework. A table rebuild (`db._rebuild_if`) runs in one transaction
  (`PRAGMA foreign_keys=OFF` around it, condition re-checked under `BEGIN IMMEDIATE`) after a
  `VACUUM INTO <db>.pre-<spec>-<timestamp>.bak` copy of the file; any failure rolls back.
  Steps: 012 (reviewlog loses its FK), 013 (`reviewlog.confidence`), 014 (cards → notes, below), 015 (creates
  `report` through `_rebuild_if`: backup + one transaction; skipped once it exists).
- Review history (`ReviewLog`) is never deleted: `card_id` has no foreign key, so deleting a card keeps its reviews
  and `streak` / `reviewed_today` don't change (spec 012).

### Notes and cards (spec 014)
- **Note** = one thing the user knows: `type` + named string `fields` (JSON). Types are fixed in `deck.NOTE_TYPES`:
  `basic` (`front`, `back`; both required; key `front`; default direction `front → back`) and `person` (`photo`
  http(s) URL, `name` required, `description` free text e.g. "Mistral CEO"; key `name`; no default: directions
  must be given). `role` / `context` were removed (spec 014a amendment): using them is a 422 "… use description".
- **Card** = one direction over its note's fields with its own FSRS state: **one prompt field → every other field
  of the type** (`prompt` / `answer`, JSON lists in the type's field order). So a person has at most three:
  `photo → name + description`, `name → photo + description`, `description → photo + name`; basic has
  `front → back` and `back → front`. The prompt field must be set and at least one answer field. The stored
  `answer` is the whole rest; reads (`Note.cards[].answer`, `Card.answer`, `back`) leave out empty fields, so a
  field set later shows up. Requests may omit `answer`; if given it must be the rest (all, or only the set ones),
  else 422. `card.note_id` → `note.id ON DELETE CASCADE`. Cards of one note are siblings.
- Validation lives in `deck` (`InvalidNote`): REST → 422 `{"detail": message}`, MCP → `ToolError`. Messages name the
  field/direction, never a value (photo URLs are private; they're never logged).
- **Sibling burying**: `deck.SIBLING_BURY = 6 h` cap. A card reviewed at `t` (its latest review) holds its
  siblings until `min(t + 6 h, its current due)`: never past its own next due (spec 014, user decision
  2026-11-22; its own reviews don't bury it). The servable queue (`deck._queue`) = due, not buried, most overdue
  first, at most one card per note; it backs `/cards/due`, `due_cards`, `stats.due`, and `stats.next_due` (earliest time a card not
  servable now becomes servable: `max(due, every sibling's hold)`). `total` / `new` count cards.
- **Held cards (spec 015)**: a card with any `Report` whose status is `open` or `waiting_user` is left out of the
  servable queue entirely (so out of `/cards/due`, `due_cards`, `stats.due`, `stats.next_due`; it doesn't bury its
  siblings). It still counts in `total` and shows in `/cards`, `/notes`. Its FSRS state is never touched.
- **`report` table**: `{id, card_id, note_id, reason: wrong|drop|doubt|rephrase|other|broken_photo, comment, status:
  open|waiting_user|resolved|dismissed, resolution, created_at, updated_at, resolved_at}`. `card_id` / `note_id` have
  no foreign key (like `ReviewLog`): a report outlives its card.
- **Migration 014**: when `card` still has `front`, each card becomes a `basic` note **with the same id** and
  `fields = {front, back}`; `card` is rebuilt with `note_id = id`, `prompt ["front"]`, `answer ["back"]`. Card ids,
  FSRS state and review logs are untouched. Backup `<db>.pre-014-<timestamp>.bak`.
- **Migration 014a** (data only, `db._fold_person_roles`): a person note with `role` / `context` gets
  `description = "description — role — context"` (set parts only); each card becomes `prompt → rest` with
  role/context mapped to `description`; a card duplicating a sibling's direction is deleted (reviews stay). Backup
  `<db>.pre-014a-<timestamp>.bak`.

### REST contract

| Method | Path | Body / query | Returns |
|---|---|---|---|
| GET | `/health` | — | `{status, build}` (no auth); `build` = 12-hex sha256 of the API's `.py` source (`build.py`) |
| GET | `/notes` | `?query=&type=basic\|person&limit=` (≤ 500, default 100; `query` = casefolded substring of any field but `photo`) | `[Note]` newest first |
| POST | `/notes` | `{type, fields, directions?: [{prompt: [field], answer?: [fields]}]}` (one prompt field, answer = the rest; no duplicate check) | `Note` (201) |
| GET/PATCH/DELETE | `/notes/{id}` | PATCH `{fields?, directions?}`: `fields` merged key by key (`""` clears); `directions` = the full desired set (kept ones keep card + schedule, new ones due now, missing ones deleted) | `Note` / 204 (note + all its cards) |
| GET | `/cards` | `?query=&limit=` (matches the card's note) | `[Card]` newest first |
| POST | `/cards` | `{front, back}` → a `basic` note `front → back` | `Card` (201) |
| GET | `/cards/due` | `?limit=` | `[Card]`: the servable queue (burying, one per note) |
| GET/PATCH/DELETE | `/cards/{id}` | PATCH `{front?, back?}` edits the note field this card shows on that side (422 if the side has several fields: use `PATCH /notes/{note_id}`); DELETE removes the direction, and the note with its last card | `Card` / 204 |
| POST | `/cards/{id}/review` | `{rating: again\|hard\|good\|easy, confidence?: 0–1}` (`confidence`: optional measured drag value, stored in `ReviewLog`, not used by FSRS; outside [0, 1] → 422 — spec 013) | rescheduled `Card` |
| POST | `/cards/{id}/report` | `{reason: wrong\|drop\|doubt\|rephrase\|other\|broken_photo, comment?: string}` (`comment` trimmed, 1–500 chars, required for `other`; bad reason/comment → 422 `{"detail": …}`; unknown card → 404 — spec 015) | `Report` (201); the card is held out of study. `broken_photo` (filed by the app) is idempotent: an active one on the card is returned with 200, no new row |
| GET | `/stats` | `?tz=` (IANA name, default `UTC`; unknown → 422 `{"detail": "Unknown time zone: <name>"}`) | `{total, due, new, reviewed_today, next_due, streak}` (`due` / `next_due`: servable queue, see burying — spec 014; `reviewed_today` and `streak` (consecutive review days ending today or yesterday) use local days in `tz` — spec 007) |

`Note` = `{id, type, fields, cards: [{id, prompt, answer, state, due, last_review}], created_at, updated_at}`.
`Card` = `{id, note_id, type, prompt, answer, fields, front, back, state: new|learning|review|relearning, due,
last_review, created_at, updated_at}`; `fields` = the whole note's; `front` / `back` = prompt / answer values joined
by `"\n"` (for old clients).
`Report` = `{id, card_id, note_id, reason, comment, status, resolution, created_at, updated_at, resolved_at, card}`;
`card` = the current `Card`, or `null` once deleted.

### MCP tools
Notes: `add_notes(notes, allow_duplicates=False)` → `{added: [Note], skipped: [Note]}` (skips a note whose type +
key (basic `front`, person `name`; casefolded, trimmed) matches an existing note or an earlier one in the call; all or
nothing on a validation error), `find_notes(query, type, limit=50)`, `update_note(note_id, fields)`,
`add_direction(note_id, prompt, answer=None)`, `remove_direction(card_id)` (refuses the last card), `delete_note(note_id)`.

Cards (thin wrappers with the `/cards` semantics; docstrings start "Prefer the note tools"): `add_cards` (basic
notes; same duplicate rule on basic fronts, returns `{added: [Card], skipped: [Card]}`), `list_cards`, `update_card`,
`delete_card`, `due_cards` (servable queue), `review_card(card_id, rating, confidence=None)`, `deck_stats(tz="UTC")`.
REST `POST /notes` / `POST /cards` always add.

Reports (spec 015): `list_reports(status="active")` → `[Report]`, oldest first (`active` = open + waiting_user;
also `all` or one status). `update_report(report_id, outcome, note)` stores `note` (non-blank) as `resolution`:
`waiting_user` (card stays held), `fixed` → resolved, `kept` → dismissed (both: card back in study, unchanged),
`deleted` → resolved + `delete_card` semantics (just closes if the card is gone). Unknown or closed report →
`ToolError`.

Server `instructions` (sent on initialize, `mcp_server.INSTRUCTIONS`) explain notes vs cards and siblings, both
types, "edit the note, not loose cards", "choose directions deliberately", minimalist cards, photo privacy, and the
burying (until the reviewed sibling is due again, at most 6 hours), and how to handle each report reason
(doubt / rephrase: ask the user before changing anything).
`allow_duplicates` is only for when the user explicitly asks.

### MCP prompts (spec 005, 014)
`quiz_me(limit=10)` (uses `due_cards` + `review_card`; shows the `prompt` fields, then the `answer` fields),
`make_cards(text, max_cards=20)` (checks `find_notes`, adds with one `add_notes` call of `basic` notes),
`add_people(text, directions=None)` (person notes from e.g. a team page: name + description, photo only if a URL is
given; asks which directions when `directions` is not given).

Connect an agent (Claude Code example):
```bash
claude mcp add --transport http la-carte http://127.0.0.1:8000/mcp \
  --header "Authorization: Bearer $LA_CARTE_API_TOKEN"
```

## iOS (`ios/`)

```
ios/
├── LaCarte.xcodeproj          app, widget extension and UI-test targets (shared scheme "LaCarte")
├── LaCarte/                   thin shell: @main App → bootstrap() + RootView(). Nothing else goes here.
├── LaCarteWidget/             thin shell: @main WidgetBundle { DeckWidget() } (spec 007)
├── LaCarteUITests/            XCUITest, owned by qa-validator
├── Config/                    Info.plists (ATS local networking, `LaCarteAppGroup`), entitlements (App Group),
│                              Signing.xcconfig
└── LaCarteKit/                Swift package — all real code
    ├── Sources/
    │   ├── AppFeature/        root reducer, composes child features, RootView entry point
    │   ├── <Name>Feature/     one module per feature (StudyFeature, DeckFeature, …)
    │   ├── APIClient/         @DependencyClient + live/in-memory implementations + models, AppGroup, TokenStore
    │   ├── AskAIClient/       copy to clipboard + open the chosen AI app, `AIApp` (spec 016)
    │   ├── DeckWidget/        Home Screen widget + its debug gallery (SwiftUI + WidgetKit, no TCA)
    │   └── DesignSystem/      tokens + reusable views (no TCA)
    └── Tests/<Module>Tests/   TestStore / Swift Testing
```

Module dependency rule (no cycles, arrows point down):
```
AppFeature → <Name>Feature → APIClient
           → DeckWidget    → DesignSystem
```
`DeckWidget` (deps `APIClient`, `DesignSystem`) is also the only product the widget extension links.
Feature tree (specs 001–004):
```
AppFeature ── study: StudyFeature                      (home, always on screen)
           └─ destination: .deck(DeckFeature)          ── destination: .editor(NoteEditorFeature)
                           .addNote(NoteEditorFeature)                 .settings(SettingsFeature)
```
Changes flow up as delegates: `CardEditor.saved` → Deck/App; `Settings.serverChanged` → Deck;
`Deck.deckChanged` → App, which sends `study(.deckChanged)` so study re-fetches.
- Features never import each other except parent → child.
- Clients and DesignSystem never import ComposableArchitecture.
- Adding a feature = new target + test target in `Package.swift` + child in `AppFeature`.

### Runtime configuration (launch environment)
| Variable | Effect |
|---|---|
| `LA_CARTE_API=mock` | In-memory deck seeded with `[Card].fixtures` (UI tests, demos) |
| `LA_CARTE_API=mock-notes` | In-memory deck seeded with `[Note].fixtures`: the 3 mock cards as `basic` notes, a `back → front` direction on "la carte", and a made-up person note (generated `data:` image) with 2 cards (spec 014b) |
| `LA_CARTE_API_URL` | API base URL (no default: without it or a stored URL the app shows "Connect your deck") |
| `LA_CARTE_API_TOKEN` | Bearer token |

On device the URL (`apiURL`) and the theme live in the **App Group suite** `UserDefaults(suiteName: AppGroup.id)`
(spec 007): `bootstrap()` sets `defaultAppStorage` to it, so `@Shared(.appStorage)` reads and writes there, and the
widget reads the same values. `AppGroup.id` = `group.$(LA_CARTE_BUNDLE_ID_PREFIX).app`, from the `LaCarteAppGroup`
Info.plist key (`.standard` when absent, e.g. unit tests). The token is in the Keychain (`TokenStore`, service
`la-carte`, account `api-token`) in the App Group's **access group**, `kSecAttrAccessibleAfterFirstUnlock`.
`bootstrap()` migrates pre-007 values once (defaults from `.standard`, the token from the default access group).
The widget fetches `/stats?tz=<device zone>` itself, caches the last result under `widget.lastStats`, and the app
reloads its timeline when it goes to the background. The live `APIClient` resolves URL and token **per request**:
launch env > stored value > none. Without both a URL and a token the app shows "Connect your deck" and makes
no request (`APIClient.isConfigured`, spec 008); a 401/403 shows "Token rejected".

Theme (spec 004): `@Shared(.appStorage(AppTheme.storageKey))` (`"theme"`), `system|light|dark|forest`; launch argument `-theme forest`
overrides it for screenshots.
