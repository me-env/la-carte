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
- Accounts (spec 030): every request resolves to one user through a bearer token; every owned row has a `user_id`
  and every `deck` function filters on it. See "Accounts and auth".
- MCP tool docstrings are the agent-facing docs: write them for an LLM reader (what, when, effects).
- Schema changes on existing tables go in `db._migrate`: idempotent, checked with `PRAGMA`, run at startup
  **before** `create_all` (so a backup is an exact copy of the old file; a missing table = fresh database, skipped).
  Plain SQL, no migration framework. A table rebuild (`db._rebuild_if`) runs in one transaction
  (`PRAGMA foreign_keys=OFF` around it, condition re-checked under `BEGIN IMMEDIATE`) after a
  `VACUUM INTO <db>.pre-<spec>-<timestamp>.bak` copy of the file; any failure rolls back.
  Steps: 012 (reviewlog loses its FK), 013 (`reviewlog.confidence`), 014 (cards → notes, below), 015 (creates
  `report` through `_rebuild_if`: backup + one transaction; skipped once it exists), 021 (creates `settings` the
  same way, no row; adds the nullable `reviewlog.stability_before` / `last_review_before` in place, like
  `confidence`: rows from before read NULL).
- Review history (`ReviewLog`) is never deleted: `card_id` has no foreign key, so deleting a card keeps its reviews
  and `streak` / `reviewed_today` don't change (spec 012). Each row also stores the card's memory state just before
  that review (`stability_before`, `last_review_before`; null when the card was new), written by `deck.review_card`
  and used only for the day's at-risk snapshot (spec 021); not exposed.

### Notes and cards (spec 014)
- **Note** = one thing the user knows: `type` + named string `fields` (JSON). Types are fixed in `deck.NOTE_TYPES`:
  `basic` (`front`, `back`; both required; key `front`; default directions both `front → back` and `back → front`,
  spec 026; legacy REST `POST /cards` makes one card `front → back`) and `person` (`photo`
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
  2026-11-22; its own reviews don't bury it). A `learning` / `relearning` card is never buried. The servable queue
  (`deck._queue`) = due, not buried, at most one card per note, in one order (specs 021, 022): `learning` /
  `relearning` cards by `due`, then `review` cards lowest FSRS retrievability first
  (`Scheduler.get_card_retrievability` at `now`), then new cards oldest first (`_card_order`); ties by `due`, then
  `_card_order`, then id. The first card of a note in that order is its one servable card. It backs
  `/cards/due`, `due_cards`, `stats.due`, and `stats.next_due` (earliest time a card not servable now
  becomes servable: `max(due, every sibling's hold)`, just `due` for a (re)learning card). `total` / `new` count
  cards. `Note.next` reads the same queue, spec 028 (`deck._candidates`: every non-held card with its ready time,
  in queue order; `next` = the note's first card ready now, else its earliest ready one, ties by queue order).
- **Due-date spreading (spec 023)**: `deck._scheduler` runs with `enable_fuzzing=False`; `deck.review_card` does
  the fuzz itself. When the result is a `review` card with an FSRS interval `i` ≥ 3 days, the new due is
  `now + k days` for one `k` in the library's fuzz window around `i` (`fsrs.scheduler.FUZZ_RANGES`), picked at
  random with Anki 24.11's load-balancer weights: 1 for an empty day, else `count^-2.15 · k^-3`, where `count` =
  other cards due in `(now + (k-1) d, now + k d]` (one query per review). Learning steps and intervals under 3 days
  are never moved; nothing about the shift is stored. RNG injectable (`rng=`) for tests.
- **Held cards (spec 015)**: a card with any `Report` whose status is `open` or `waiting_user` is left out of the
  servable queue entirely (so out of `/cards/due`, `due_cards`, `stats.due`, `stats.next_due`; it doesn't bury its
  siblings). It still counts in `total` and shows in `/cards`, `/notes`. Its FSRS state is never touched.
- **New cards are never held (spec 021)**: the servable queue serves every new card (the 014 sibling hold applies
  to new siblings as to any card; no one-per-note rule). The stored setting is only the size M of the new-card steps
  the app shows.
- **The daily ladder (spec 021 v3), display only**: `/stats` reports counts, the app arranges them into steps (At
  risk, Reviews, then steps of M new cards); nothing about the queue changes. With `start_of_day` = local midnight
  in `tz`:
  - At risk: the snapshot S = cards with a memory state at `start_of_day` whose FSRS retrievability then
    (`_scheduler.get_card_retrievability`) was below `deck.AT_RISK_RECALL` (0.8). A card reviewed today is judged by
    the `*_before` state of its first review today (done, even if deleted since); any other card by its current
    fields (waiting, unless held by a report). `at_risk_done` = S cards reviewed today, `at_risk_total` = done +
    waiting; both 0 when the total is below `deck.AT_RISK_MIN` (10).
  - Reviews: `reviews_done = reviewed_today - new_today`; `reviews_total` = done + cards in the servable queue now
    whose `last_review` is before `start_of_day` (a card failed today or a learning step doesn't reopen it).
- **`settings` table** (spec 021): one row, `id = 1`, `new_cards_per_day` = the new-card milestone size M (default
  15, 1–200; a stored 0 reads 15). A missing row means the defaults; `deck.get_milestone` reads it,
  `deck.set_milestone` upserts it (`InvalidSetting` outside 1–200). Migration 021 creates the table on a pre-021
  database (backup `<db>.pre-021-<timestamp>.bak`).
- **`report` table**: `{id, card_id, note_id, reason: wrong|drop|doubt|rephrase|other|broken_photo, comment, status:
  open|waiting_user|resolved|dismissed, resolution, created_at, updated_at, resolved_at}`. `card_id` / `note_id` have
  no foreign key (like `ReviewLog`): a report outlives its card.
- **`feedback` table** (spec 025): `{id, kind, message, status: open|done, resolution, created_at, closed_at}`.
  Created by `create_all` (new table, no existing data touched: no `_migrate` step, no backup).
- **`activityevent` table** (spec 029): what the user did in the app, `{id (client UUID), kind, at (UTC), tz,
  session, card_id, app_version, build, os, data (JSON), received_at}`, indexed on `at`, `card_id`, `kind`. Created by
  `create_all` like `feedback`. Ingest is idempotent on `id` and skips invalid events one by one. Events older than
  `deck.ACTIVITY_RETENTION` (90 days, by `at`) are pruned once at startup. Never touches the deck.
- **Migration 014**: when `card` still has `front`, each card becomes a `basic` note **with the same id** and
  `fields = {front, back}`; `card` is rebuilt with `note_id = id`, `prompt ["front"]`, `answer ["back"]`. Card ids,
  FSRS state and review logs are untouched. Backup `<db>.pre-014-<timestamp>.bak`.
- **Migration 014a** (data only, `db._fold_person_roles`): a person note with `role` / `context` gets
  `description = "description — role — context"` (set parts only); each card becomes `prompt → rest` with
  role/context mapped to `description`; a card duplicating a sibling's direction is deleted (reviews stay). Backup
  `<db>.pre-014a-<timestamp>.bak`.

### Accounts and auth (spec 030)
Principles (non-negotiable):
- **Never passwords.** No passwords or password hashes are stored; no password login, reset or magic link, ever.
  Identity is always OAuth / OpenID Connect with an external provider.
- **Two identity providers, Apple and Google** (App Store guideline 4.8), in `identity.py` (`apple`, `google`, and
  `fake` for tests/e2e only). Google: browser flow through `/authorize`. Apple: native in the app
  (`POST /oauth/apple`, identity token checked against Apple's JWKS) and a web flow on the agents' consent page.
- **Minimum data**: Google `openid email`, Apple `email` only (no name, no picture); stored: the provider's `sub` +
  the verified email (Apple relay addresses as is); unverified emails are refused. No Google token is kept (the
  access token is revoked right after sign-in); Apple's refresh token is kept only to revoke Sign in with Apple
  when the account is deleted.
- **Account = (provider, `sub`)**, one identity per account, never merged by email: a new identity whose email
  belongs to another account is refused (`use_google` / `use_apple` / `email_in_use`). The only email match: the
  migrated owner row (no identity yet) is claimed by the first verified sign-in with `LA_CARTE_OWNER_EMAIL`.
- **Sign-up mode** `LA_CARTE_SIGNUP`: `open` (default; required for the App Store, App Review uses its own Apple
  ID) or `allowlist` (`LA_CARTE_ALLOWED_EMAILS` + the owner).
- **Deletion** (`DELETE /me`): revokes Sign in with Apple (best effort), then deletes every row the user owns in
  one transaction.
- **Our tokens, opaque, hashed**: `lc_at_` access (1 h), `lc_rt_` refresh (rotated; reuse revokes the family),
  `lc_pat_` personal access tokens; only SHA-256 stored (`apitoken`), so no signing key. No token passthrough.
- **OAuth first, PATs second**: agents connect with OAuth; PATs (scripts, CI/e2e, MCP clients without OAuth) are
  minted only from the app by a Google-signed-in user (`POST /me/tokens` needs an `la-carte-ios` access token),
  shown once, revocable, optional expiry. The old `LA_CARTE_API_TOKEN` is imported once as the owner's PAT `legacy`.
- Cross-user access answers "not found", never "forbidden"; a pytest matrix covers every REST route and MCP tool.

Pieces: `auth.py` (mint/verify tokens, `CurrentUser` dependency, MCP token verification), `oauth.py` (the MCP SDK
`OAuthAuthorizationServerProvider`: `/authorize`, `/token`, `/register` (DCR), `/revoke`, metadata), `identity.py`
(providers). Tables `user`, `identity`, `apitoken`, `oauthclient`, `authrequest`, `authcode`; `user_id` on `note`,
`card`, `reviewlog`, `report`, `feedback`, `activityevent`; `settings` keyed by `user_id`. Flow: client →
`/authorize` → (agents: `/oauth/consent`, Apple or Google) → provider → `/oauth/callback` → our code → client →
`/token`; the iOS app's Apple path is `POST /oauth/apple` straight to tokens. Public paths: `/health`, icons, the
site (`/`, `/privacy`, `/support`, `/site/*`), `/.well-known/*`, `/authorize`, `/token`, `/register`, `/revoke`,
`/oauth/*`. Detail: specs 030, 030a, 030b, 030e, 030g.

### Encryption (spec 032)
Encryption at rest, always on: the SQLite file is SQLCipher-encrypted with `LA_CARTE_DB_KEY` (64 hex, required in
production; `PRAGMA key` first on every connection; a plaintext file is encrypted once at startup). A stolen file or
backup is unreadable; the server and its operator can read the data (not end-to-end). Never log the key. A per-user
key was rejected (2026-11-28, backlog #72): remote MCP agents need the server to hold it.

### Web pages (spec 030h)
The API serves a small static site from `api/src/la_carte_api/site/` (no JavaScript, no external resources, no
cookies): the landing page `/`, `/privacy`, `/support`, and `/site/*` assets. Placeholders (`{{support_email}}`,
`{{app_store_url}}`, `{{operator}}`) are filled from env at startup, so no hostname or personal data is committed.
**`/privacy` must match what is actually collected**: any change to `ios/LaCarte/PrivacyInfo.xcprivacy`, to what the
server stores, or to retention updates the privacy page in the same change.

### REST contract

| Method | Path | Body / query | Returns |
|---|---|---|---|
| GET | `/health` | — | `{status, build}` (no auth); `build` = 12-hex sha256 of the API's `.py` source (`build.py`) |
| GET | `/favicon.ico`, `/icon.png` (512), `/apple-touch-icon.png` (180), `/icon.svg` | — | The la-carte icon (no auth, cached 1 day), from `docs/design/brand/render.py`; MCP serverInfo `icons` points at it when `LA_CARTE_PUBLIC_URL` is set |
| GET | `/`, `/privacy`, `/support`, `/site/*` | — | The landing page, privacy policy, support page and their assets (HTML, no auth — spec 030h) |
| POST | `/oauth/apple` | form `client_id=la-carte-ios`, `identity_token`, `authorization_code`, `nonce` | the `/token` body, or 400 `{error, error_description}` (spec 030e) |
| GET/DELETE | `/me` | — | `{id, email, provider: apple\|google\|null, created_at}` / 204 (revokes Sign in with Apple, deletes the account and everything it owns — specs 030a, 030e) |
| GET/POST | `/me/tokens` | POST `{name, scope: deck\|stats, expires_in_days?}` (only with an app access token) | `[PersonalToken]` / `PersonalToken` + `token` once (201) — specs 030a/b |
| DELETE | `/me/tokens/{id}` | — | 204 (revokes) |
| GET | `/notes` | `?query=&type=basic\|person&limit=` (≤ 500, default 100; `query` = casefolded substring of any field but `photo`) | `[Note]` newest first. Every `Note` (all note responses, REST and MCP) has `next`: `{card_id, ready_at}` = the card Study serves first for it and when (`ready_at` ≤ now: in the queue now), or `null` when every card is held by a report (spec 028) |
| POST | `/notes` | `{type, fields, directions?: [{prompt: [field], answer?: [fields]}]}` (one prompt field, answer = the rest; no duplicate check) | `Note` (201) |
| GET/PATCH/DELETE | `/notes/{id}` | PATCH `{fields?, directions?}`: `fields` merged key by key (`""` clears); `directions` = the full desired set (kept ones keep card + schedule, new ones due now, missing ones deleted) | `Note` / 204 (note + all its cards) |
| GET | `/cards` | `?query=&limit=` (matches the card's note) | `[Card]` newest first |
| POST | `/cards` | `{front, back}` → a `basic` note `front → back` | `Card` (201) |
| GET | `/cards/due` | `?limit=` | `[Card]`: the servable queue (burying, one per note) |
| GET/PATCH/DELETE | `/cards/{id}` | PATCH `{front?, back?}` edits the note field this card shows on that side (422 if the side has several fields: use `PATCH /notes/{note_id}`); DELETE removes the direction, and the note with its last card | `Card` / 204 |
| POST | `/cards/{id}/review` | `{rating: again\|hard\|good\|easy, confidence?: 0–1}` (`confidence`: optional measured drag value, stored in `ReviewLog`, not used by FSRS; outside [0, 1] → 422 — spec 013) | rescheduled `Card` |
| POST | `/cards/{id}/report` | `{reason: wrong\|drop\|doubt\|rephrase\|other\|broken_photo, comment?: string}` (`comment` trimmed, 1–500 chars, required for `other`; bad reason/comment → 422 `{"detail": …}`; unknown card → 404 — spec 015) | `Report` (201); the card is held out of study. `broken_photo` (filed by the app) is idempotent: an active one on the card is returned with 200, no new row |
| GET | `/stats` | `?tz=` (IANA name, default `UTC`; unknown → 422 `{"detail": "Unknown time zone: <name>"}`) | `{total, due, new, reviewed_today, next_due, new_today, milestone, streak, streak_start, history_start, history, due_new, at_risk_total, at_risk_done, reviews_total, reviews_done}` (`due` / `next_due`: servable queue, see burying — spec 014; `due_new`: never-reviewed cards in that queue; `new_today`: distinct cards first reviewed today, `milestone`: the stored new-card step size, 0 → 15, `at_risk_total` / `at_risk_done` (0 / 0 when the step doesn't exist today) and `reviews_total` / `reviews_done`: the daily ladder, display only, see "The daily ladder" — spec 021; `history`: one letter per local day from `history_start` (first review day, or today) to today, `s` studied / `f` frozen / `m` missed / `p` today not yet studied; a missed day is frozen when the day before is studied, no freeze in the 6 days before, and the day after is studied or today; `streak` = trailing `s`/`f` days ending today, or yesterday while today is `p`, starting `streak_start` (null when 0) — spec 024; all per-day fields use local days in `tz` — spec 007) |
| POST | `/activity` | `{events: [{id, kind, at, tz, session, app_version, build, os, card_id, data}]}` (≤ 500, else 413; each event validated on its own — spec 029) | `{stored, duplicates, rejected}` |
| GET | `/activity` | `?since=&until=&card_id=&kind=&session=&limit=` (≤ 1000, default 100) | `[ActivityEvent]` newest first (`ActivityEventRead`, + `local_at`) |

`Note` = `{id, type, fields, cards: [{id, prompt, answer, state, due, last_review}], next: {card_id, ready_at} | null, created_at, updated_at}`.
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

Cards: `due_cards` (servable queue), `review_card(card_id, rating, confidence=None)`, `deck_stats(tz="UTC")`
(the same `DeckStats` as `/stats`; fields, the ladder, freezes and the `history` alphabet explained in its docstring).
REST `POST /notes` / `POST /cards` always add.

New-card milestone (spec 021, MCP only): `new_card_milestone(value=None)` reads the step size, or sets it (1–200,
else `ToolError` "new_card_milestone must be between 1 and 200."), and returns `MilestoneSetting` = `{milestone}`.
The MCP reply of `add_notes` (`AddNotesReply`) adds `new` (never-reviewed cards after the insert) and `milestone`;
REST `POST /notes`, `POST /cards` keep their models.

Reports (spec 015): `list_reports(status="active")` → `[Report]`, oldest first (`active` = open + waiting_user;
also `all` or one status). `update_report(report_id, outcome, note)` stores `note` (non-blank) as `resolution`:
`waiting_user` (card stays held), `fixed` → resolved, `kept` → dismissed (both: card back in study, unchanged),
`deleted` → resolved + `deck.delete_card` semantics (just closes if the card is gone). Unknown or closed report →
`ToolError`.

Feedback (spec 025, MCP only): `send_feedback(message, kind="other")` → `Feedback` (`kind`: bug | confusing |
missing | friction | other; `message` trimmed, 1–2000 chars, else `ToolError`), `list_feedback(status="open")`
(open | done | all, oldest first), `close_feedback(feedback_id, note=None)` → `done`, `note` stored as
`resolution` (unknown or already done → `ToolError`). Feedback is about the app / tools / experience, never one card
(that's a report), and stays in this server's database: nothing is sent anywhere.

Activity (spec 029): `activity_log(since, until, card_id, kind, session, limit=100)` → `[ActivityEventRead]` newest
first, the same as `GET /activity`. `list_feedback` / `list_reports` descriptions point to it for correlation.

History (spec 031, MCP only): `review_history(since, until, card_id, note_id, rating, limit=100)` → `[ReviewEntry]`
= `{card_id, reviewed_at, rating, confidence, card: Card | null}` over `ReviewLog` (app and MCP ratings, never
pruned), newest first; `struggling_cards(since, limit=20)` → `[StrugglingCard]` = `{card, reviews, again,
last_again_at}`, existing cards with ≥ 1 `again`, most `again` first.

Removed in spec 031 (superseded by the note tools; REST `/cards` unchanged): `add_cards` → `add_notes` (one card:
`directions: [{"prompt": ["front"]}]`), `list_cards` → `find_notes`, `update_card` → `update_note`, `delete_card` →
`remove_direction` / `delete_note`.

Server `instructions` (sent on initialize, `mcp_server.INSTRUCTIONS`) explain notes vs cards and siblings, both
types, "edit the note, not loose cards", "basic defaults to both directions; person: pick directions deliberately", minimalist cards, photo privacy, and the
burying (until the reviewed sibling is due again, at most 6 hours; (re)learning cards never held), and how to handle
each report reason (doubt / rephrase: ask the user before changing anything), and new cards (never held back, shown by the app
in steps of `milestone`; tell the user how many wait (`new`); change the step size with `new_card_milestone` only
when the user asks). No text says reviews must be done daily (the streak needs one review a day, spec 024).
`allow_duplicates` is only for when the user explicitly asks.

### MCP prompts (spec 005, 014, 015)
`quiz_me(limit=10)` (uses `due_cards` + `review_card`; shows the `prompt` fields, then the `answer` fields),
`make_cards(text, max_cards=20)` (checks `find_notes`, adds with one `add_notes` call of `basic` notes),
`add_people(text, directions=None)` (person notes from e.g. a team page: name + description, photo only if a URL is
given; asks which directions when `directions` is not given),
`handle_reports()` (works through active `list_reports` per the server instructions, asks the user where they say to;
also what a recurring report watcher runs).

Connect an agent (Claude Code example; OAuth, a browser opens for Google — spec 030b):
```bash
claude mcp add --transport http la-carte https://<api>/mcp
```
Without OAuth (scripts, clients that only send headers): `--header "Authorization: Bearer lc_pat_…"` with a PAT
created in the app (spec 030d).

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
    │   ├── APIClient/         @DependencyClient + live/in-memory implementations + models, AppGroup, TokenStore,
│   │                      AuthClient + SessionStore (sign-in, refresh — spec 030c)
│   ├── SignInFeature/     the sign-in screen (spec 030c)
    │   ├── AskAIClient/       copy to clipboard + open the chosen AI app, `AIApp` (spec 016)
    │   ├── ActivityClient/    fire-and-forget activity log: file buffer + lazy uploader to `POST /activity` (spec 029)
    │   ├── DeckWidget/        Home Screen widget + its debug gallery (SwiftUI + WidgetKit, no TCA)
    │   └── DesignSystem/      tokens + reusable views (no TCA)
    └── Tests/<Module>Tests/   TestStore / Swift Testing
```

Module dependency rule (no cycles, arrows point down):
```
AppFeature → <Name>Feature → ActivityClient → APIClient
           → DeckWidget    → DesignSystem
```
`DeckWidget` (deps `APIClient`, `DesignSystem`) is also the only product the widget extension links.
Feature tree (specs 001–004, 030c/d):
```
AppFeature ── study: StudyFeature                      (home, always on screen)
           └─ destination: .deck(DeckFeature)          ── destination: .editor(NoteEditorFeature)
                           .addNote(NoteEditorFeature)                 .settings(SettingsFeature)
                           .settings(SettingsFeature)  ── AccessTokensFeature (030d)
                           .signIn(SignInFeature)      (full-screen cover while signed out — 030c)
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
| `LA_CARTE_API_URL` | API base URL; overrides the build-time `LaCarteDefaultAPIURL` (development, UI tests). Before 030c: no default, a stored URL from Settings |
| `LA_CARTE_API_TOKEN` | Bearer token (a PAT; skips sign-in) |
| `LA_CARTE_AUTH=signed-out` / `not-allowed` / `use-google` | Mock modes: start signed out; mock sign-in (Apple or Google) succeeds / is refused / Apple is refused with "use Google" (specs 030c, 030f) |
| `LA_CARTE_ACTIVITY=off` | Activity log disabled (`log` is a no-op; QA baseline, spec 029) |
| `LA_CARTE_ACTIVITY_URL` | Where activity is sent instead of the API URL; in `mock*` modes activity is sent only when this is set (spec 029) |

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
Accounts (spec 030c): the sign-in session `{baseURL, accessToken, refreshToken, expiresAt}` is Keychain account
`session` (app only, no access group), refreshed by `SessionStore` (once per 401, shared in-flight refresh; dead
refresh token → signed out → `SignInFeature`). The widget uses its own `stats`-scoped PAT, account `widget-token`
in the App Group access group, and never refreshes. Credential order: launch env > `session` > legacy `api-token`;
URL order: launch env > Info.plist `LaCarteDefaultAPIURL` (build setting `LA_CARTE_DEFAULT_API_URL`, set by CI; app
and widget). The stored `apiURL` is no longer read, and the app has no server URL setting: self-hosters build from
source with their own URL (spec 030 "Self-hosting").

Theme (spec 004): `@Shared(.appStorage(AppTheme.storageKey))` (`"theme"`), `system|light|dark|forest`; launch argument `-theme forest`
overrides it for screenshots.
