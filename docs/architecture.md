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
| `models.py` | SQLModel tables (`Card`, `ReviewLog`) + public pydantic schemas (`CardRead`, `CardCreate`, …) |
| `deck.py` | **All behavior.** Plain functions taking a `Session`. Testable without HTTP. |
| `rest.py` | FastAPI routes, thin wrappers over `deck` (consumed by iOS) |
| `mcp_server.py` | MCP tools, thin wrappers over `deck` (consumed by agents) |
| `app.py` | Assembly: engine, routes, MCP mount at `/mcp`, bearer-token middleware |
| `config.py` | `LA_CARTE_*` env settings |

Rules:
- New behavior goes in `deck.py` first, then exposed via REST **and** MCP when both make sense.
- REST and MCP return the same schemas (`CardRead`, `DeckStats`).
- Times are UTC everywhere; `now` is injectable in `deck` functions for tests.
- No login. Optional single bearer token (`LA_CARTE_API_TOKEN`) protects REST + MCP when deployed.
- MCP tool docstrings are the agent-facing docs: write them for an LLM reader (what, when, effects).

### REST contract

| Method | Path | Body / query | Returns |
|---|---|---|---|
| GET | `/health` | — | `{status, build}` (no auth); `build` = 12-hex sha256 of the API's `.py` source (`build.py`) |
| GET | `/cards` | `?query=&limit=` | `[Card]` newest first |
| POST | `/cards` | `{front, back}` | `Card` (201) |
| GET | `/cards/due` | `?limit=` | `[Card]` most overdue first |
| GET/PATCH/DELETE | `/cards/{id}` | PATCH `{front?, back?}` | `Card` / 204 |
| POST | `/cards/{id}/review` | `{rating: again\|hard\|good\|easy}` | rescheduled `Card` |
| GET | `/stats` | `?tz=` (IANA name, default `UTC`; unknown → 422 `{"detail": "Unknown time zone: <name>"}`) | `{total, due, new, reviewed_today, next_due, streak}` (`next_due`: earliest due after now, or null — spec 001; `reviewed_today` and `streak` (consecutive review days ending today or yesterday) use local days in `tz` — spec 007) |

`Card` = `{id, front, back, state: new|learning|review|relearning, due, last_review, created_at, updated_at}`.

### MCP tools
`add_cards`, `list_cards`, `update_card`, `delete_card`, `due_cards`, `review_card`, `deck_stats(tz="UTC")`.

`add_cards` skips cards whose front already exists (case-insensitive, surrounding whitespace ignored; also within
one call, first wins) unless `allow_duplicates=true`, and returns `{added: [Card], skipped: [Card]}` where `skipped`
holds the existing matching cards (spec 005). REST `POST /cards` always adds.

Server `instructions` (sent on initialize) tell agents: minimalist cards (front = word/short question, back =
shortest answer, one fact per card) and no duplicates (check `list_cards` first; reuse, `update_card`, or tell the
user). `allow_duplicates` is only for when the user explicitly asks.

### MCP prompts (spec 005)
`quiz_me(limit=10)` (uses `due_cards` + `review_card`), `make_cards(text, max_cards=20)` (uses `add_cards`).

Connect an agent (Claude Code example):
```bash
claude mcp add --transport http la-carte http://127.0.0.1:8000/mcp \
  --header "Authorization: Bearer $LA_CARTE_API_TOKEN"
```

## iOS (`ios/`)

```
ios/
├── LaCarte.xcodeproj          app target + UI-test target (shared scheme "LaCarte")
├── LaCarte/                   thin shell: @main App → RootView(). Nothing else goes here.
├── LaCarteUITests/            XCUITest, owned by qa-validator
├── Config/Info.plist          merged into the generated plist (ATS local networking)
└── LaCarteKit/                Swift package — all real code
    ├── Sources/
    │   ├── AppFeature/        root reducer, composes child features, RootView entry point
    │   ├── <Name>Feature/     one module per feature (StudyFeature, DeckFeature, …)
    │   ├── APIClient/         @DependencyClient + live/in-memory implementations + models
    │   └── DesignSystem/      tokens + reusable views (no TCA)
    └── Tests/<Module>Tests/   TestStore / Swift Testing
```

Module dependency rule (no cycles, arrows point down):
```
AppFeature → <Name>Feature → APIClient
                           → DesignSystem
```
Feature tree (specs 001–004):
```
AppFeature ── study: StudyFeature                      (home, always on screen)
           └─ destination: .deck(DeckFeature)          ── destination: .editor(CardEditorFeature)
                           .addCard(CardEditorFeature)                 .settings(SettingsFeature)
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
| `LA_CARTE_API_URL` | API base URL (no default: without it or a stored URL the app shows "Connect your deck") |
| `LA_CARTE_API_TOKEN` | Bearer token |

On device (spec 003) the URL is stored in `UserDefaults` key `apiURL` (`@Shared(.appStorage)`) and the token in
the Keychain (`TokenStore`). The live `APIClient` resolves both **per request**:
launch env > stored value > none. Without both a URL and a token the app shows "Connect your deck" and makes
no request (`APIClient.isConfigured`, spec 008); a 401/403 shows "Token rejected".

Theme (spec 004): `@Shared(.appStorage("theme"))`, `system|light|dark|forest`; launch argument `-theme forest`
overrides it for screenshots.
