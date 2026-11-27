# 029 — Activity log

Status: ready
Owners: api-engineer ∥ ios-engineer (the contract below is fixed, both can start at once) → code-reviewer →
qa-validator
Depends on: 025 (feedback tools, merged: their descriptions link the new tool). No Study, Deck or editor behavior
changes.
Design reference: none (no screen, no visible change).

## Goal
The app records what the user does (card shown, answer revealed, rated, note saved, app foreground, queue fetched,
errors…) as dated events and sends them, lazily and invisibly, to the user's own la-carte server. When the user later
gives feedback ("I just created this card, why don't I see it?", "this card displayed badly"), an agent reads the
log around that moment with `activity_log` and sees what really happened. The user must never feel the logging: same
speed, no UI, offline or not.

## User stories
- As the user, I study exactly as before, online, offline or with a slow server, and notice nothing.
- As the user, I tell an agent "the card I just saw looked broken" and it finds the card and what I did with it.
- As the developer triaging feedback, I ask an agent to correlate each `list_feedback` item with the activity
  around its `created_at`.

## What exists today (checked 2026-11-25)
- `ReviewLog` (server) stores each rating (`card_id`, `rating`, `reviewed_at`, `confidence`, memory state before).
  It's scheduling history, never deleted; it is **not** replaced or touched by this spec.
- Ratings, reports and edits are sent online and awaited (`StudyFeature.review` → `apiClient.review`, blocking the
  buttons until answered). The app has **no offline queue** (backlog #9 deferred) and no local persistence of
  requests. This spec does not add one for ratings: only the activity log is buffered.
- Spec 025 feedback is MCP only, in the `feedback` table on the same server.

## Decisions
1. **Events, not analytics.** A flat, dated list of what happened, for correlating with feedback. No aggregates,
   funnels, dashboards or derived metrics.
2. **Stays on the user's server.** Events go only to the la-carte server the app is configured for (same URL and
   token as everything else). No third-party SDK, no other endpoint. Payloads carry **no free text from the user**:
   ids, field *names*, enums, counts, durations. Never card text, field values, photo URLs, search queries or report
   comments.
3. **Fire and forget on the device.** Features call `activity.log(_:)`, a synchronous, non-throwing call that only
   hands the event to a background actor (an `AsyncStream` continuation `yield`). Writing the file, encoding and
   sending all happen off the main actor, at background/utility priority. Logging never changes state, never shows UI,
   never fails visibly.
4. **File-backed buffer, deleted on acknowledgement.** Events append to a JSON Lines file in the app's Application
   Support (`activity.jsonl`, not the App Group: the widget doesn't log). A batch is removed from the file only after
   the server answers 2xx. Event ids are client UUIDs; the server ignores ids it already has, so a retry after a lost
   response can't duplicate.
5. **Cap: 5,000 events, oldest dropped.** About 400 B each → ~2 MB worst case; a heavy study day is a few hundred
   events, so 5,000 covers about a week offline. Checked when appending (trim when the file passes 5,500 lines, to
   amortise the rewrite).
6. **Lazy flush.** The uploader sends when any of these happen, never more often than one request in flight:
   - 25 or more events are waiting;
   - the oldest waiting event is 60 s old;
   - launch, `app_foreground`, `app_background` (one attempt; if iOS suspends the app it resumes on the next
     foreground).
   Batches of at most 200 events, oldest first, looped until the buffer is empty or a request fails. After a failure:
   back off 30 s, doubling to 15 min max; reset on success or on `app_foreground`. Not configured (no URL or token):
   events still buffer, nothing is sent.
7. **Outcomes per HTTP status**: 2xx → delete the batch. 400 / 413 / 422 → delete the batch too (it can never
   succeed; the server already skips bad events one by one, so this only guards against a malformed request).
   Anything else (no network, timeout, 401/403, 404 from a server without this endpoint, 429, 5xx) → keep, back off.
8. **Own URLSession.** The uploader uses its own ephemeral `URLSession` (`timeoutIntervalForRequest` 20 s,
   `httpMaximumConnectionsPerHost` 1, `networkServiceType` `.background`, no `waitsForConnectivity`), so a slow or
   hung activity request never occupies a connection Study needs.
9. **Device time + zone, server receipt time.** Each event has `at` = device clock as ISO 8601 with milliseconds
   and offset, plus `tz` = IANA zone. The server stores `at` in UTC and adds `received_at` (server clock), so a wrong
   device clock is visible.
10. **Session.** A new `session` UUID at launch and at every `app_foreground`; every event carries the current one.
11. **Retention: 90 days**, by `at`, pruned once at server startup (`deck.ACTIVITY_RETENTION`). No setting.
12. **Lenient ingest.** The server validates each event on its own and skips invalid ones (counted as `rejected`),
    so one bad event (or a kind a newer app invents) never blocks the queue. `kind` is a short snake_case string,
    not an enum: unknown kinds are stored.
13. **Timing rule.** Events about user input (`answer_revealed`, `rated`) are logged at the moment of input. Events
    about a server result (`queue_fetched`, `note_created`, `note_edited`, `note_deleted`, `report_sent`,
    `deck_loaded`) are logged when the success response arrives. Failures log `api_error`.

## Events
Common envelope (every event): `id` (UUID), `kind`, `at`, `tz`, `session`, `app_version` (`CFBundleShortVersionString`),
`build` (`CFBundleVersion`), `os` (e.g. `"iOS 26.1"`), `card_id` (UUID or null: set when the event is about one
card, so the server can index it), `data` (object, kind-specific, below).

| Kind | When | `card_id` | `data` |
|---|---|---|---|
| `app_foreground` | Study's scene phase becomes `.active` (including the first launch) | — | `{}` |
| `app_background` | scene phase becomes `.background` | — | `{}` |
| `queue_fetched` | `queueResponse(.success)` in Study | — | `{count, due, new, total, next_due}` (`count` = cards returned; the others from the stats in that response; `next_due` ISO or null) |
| `card_shown` | the visible card changes: `cards.first?.id` differs from the last one shown while `phase == .studying` | the card | `{note_id, type, prompt}` (`prompt` = field names, e.g. `["photo"]`) |
| `answer_revealed` | `revealTapped` / `cardTapped` turning `isRevealed` from false to true | the card | `{ms_since_shown}` |
| `rated` | a rating is sent (`ratingTapped`, or `swipeEnded` that yields a rating) | the card | `{rating, input: "button"\|"drag", ms_to_reveal, ms_to_rate}` (`ms_to_reveal` = shown → revealed, `ms_to_rate` = revealed → rated; null if not revealed) |
| `report_sent` | `reportResponse(.success)` and `brokenPhotoReportResponse(.success)` | the card | `{reason}` (never the comment) |
| `photo_failed` | `photoLoadFailed` | the card | `{side: "front"\|"back"}` (never the URL) |
| `note_created` | `NoteEditorFeature.saveResponse(.success)` for a new note | — | `{note_id, type, directions}` (count) |
| `note_edited` | editor `saveResponse(.success)` for an existing note, and Study `editSaveResponse(.success)` | Study: the card | `{note_id, source: "editor"\|"inline"}` |
| `note_deleted` | `DeckFeature.deleteResponse(.success)` | — | `{note_id}` |
| `deck_loaded` | `DeckFeature.notesResponse(.success)` | — | `{count, query: true\|false}` (whether a search was active, never its text) |
| `api_error` | any `.failure` of the responses above (Study queue / ladder / review / report / broken-photo report / inline edit, Deck notes / delete, editor save) | the card when there is one | `{request, status, error}`: `request` one of `queue`, `stats`, `review`, `report`, `update_card`, `notes`, `add_note`, `update_note`, `delete_note`; `status` = HTTP status or 0 without a response; `error` = `URLError` code name or the first 200 chars of the server's string `detail`, else empty (server messages never contain values, architecture.md; other bodies, like a 422's `input`, can) |

Durations are whole milliseconds from `ActivityClient.now` (state keeps `shownAt` / `revealedAt`).

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| **API** | | |
| 1 | `POST /activity` with `{events: [e1, e2]}` (valid envelopes) returns 200 `{stored: 2, duplicates: 0, rejected: 0}` and both rows are in `activityevent`, `at` stored in UTC, `received_at` set by the server | pytest |
| 2 | Posting the same batch again returns `{stored: 0, duplicates: 2, rejected: 0}`; the table still has 2 rows (idempotent ids) | pytest |
| 3 | A batch with one invalid event (bad `kind` pattern, naive `at`, `data` over 4 KB, missing `id`) and one valid one returns 200 `{stored: 1, duplicates: 0, rejected: 1}` | pytest |
| 4 | An unknown but well-formed `kind` (`"future_thing"`) is stored | pytest |
| 5 | More than 500 events in one request → 413; nothing stored. Without the bearer token (when configured) → 401 like every route | pytest |
| 6 | `GET /activity` and MCP `activity_log` return the same `ActivityEventRead` list, newest first; `since` / `until` (ISO 8601; `since ≤ at < until`), `card_id`, `kind` and `session` filter; `limit` defaults to 100, max 1000 (above → 422 / `ToolError`) | pytest |
| 7 | Each returned event has `local_at` = `at` in its own `tz` (ISO with offset), next to `at` in UTC | pytest |
| 8 | At startup, events with `at` older than 90 days are deleted; newer ones and every other table are untouched | pytest (db test) |
| 9 | On a pre-029 database file, startup creates `activityevent` (with indexes on `at`, `card_id`, `kind`) and writes no backup | pytest (db test) |
| 10 | Posting activity changes nothing in the deck: cards, notes, reviews, reports and `/stats` are identical before and after | pytest |
| 11 | `list_feedback` and `list_reports` descriptions mention `activity_log`, and `INSTRUCTIONS` has the Activity paragraph | pytest |
| **iOS: client** | | |
| 12 | `ActivityClient.live` `log` returns immediately while sending is stuck: 1,000 `log` calls with a `send` that never returns complete in under 50 ms on the calling task, and all 1,000 end up in the buffer file | unit (`ActivityClientTests`) |
| 13 | Events survive a restart: events written by one buffer instance are read and sent by a new instance on the same file | unit |
| 14 | A batch is removed from the file only after `send` succeeds; on a thrown error (no network, 500, 401) it stays and is sent again on the next flush with the **same ids** | unit |
| 15 | A 400 / 413 / 422 answer drops the batch; the next batch is sent | unit |
| 16 | Flush triggers: 25 waiting events send at once; fewer are sent 60 s after the oldest (driven by an injected clock); `app_foreground` / `app_background` trigger a flush; at most one request in flight; batches ≤ 200, oldest first | unit |
| 17 | Backoff after a failure: 30 s, 60 s, … capped at 15 min; reset on success and on `app_foreground` | unit |
| 18 | Over 5,000 events, the oldest are dropped (after appending 6,000 with sending off, the file holds the newest 5,000) | unit |
| 19 | Envelope encoding: `ActivityEvent` encodes snake_case keys, `at` as `yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ` with the device offset, `tz`, `session`, `app_version`, `build`, `os`, `card_id` (null when absent), `data` (matches the request example below) | unit (`DecodingTests`) |
| 20 | `LA_CARTE_ACTIVITY=off` makes `log` a no-op; in `mock*` API modes, events are sent only when `LA_CARTE_ACTIVITY_URL` is set (otherwise `log` is a no-op) | unit |
| **iOS: features** (TestStore with `ActivityClient.recording`) | | |
| 21 | Study: scene `.active` logs `app_foreground`; `.background` logs `app_background` | unit |
| 22 | Study: a queue response logs `queue_fetched` with count/due/new/total/next_due, then `card_shown` for the first card (note id, type, prompt names); the same card served again by a refresh logs no second `card_shown` | unit |
| 23 | Study: reveal 1.5 s after shown logs `answer_revealed {ms_since_shown: 1500}`; rating "good" by button 2 s later logs `rated {rating: good, input: button, ms_to_reveal: 1500, ms_to_rate: 2000}`; the next card logs `card_shown` | unit |
| 24 | Study: a drag release that rates logs `rated` with `input: drag`; a release that doesn't rate logs nothing | unit |
| 25 | Study: a failing review logs `rated` then `api_error {request: review, status, error}`; an offline queue fetch logs `api_error {request: queue, status: 0}` | unit |
| 26 | Study: report success logs `report_sent {reason}` without the comment; a broken photo logs `photo_failed {side}` then `report_sent {reason: broken_photo}`; inline edit success logs `note_edited {source: inline}` | unit |
| 27 | Editor: saving a new note logs `note_created {note_id, type, directions}`; saving an existing note logs `note_edited {source: editor}`; a save failure logs `api_error` | unit |
| 28 | Deck: a load logs `deck_loaded {count, query}`; a search logs `query: true` and no search text; a delete logs `note_deleted` | unit |
| 29 | No logging changes state: every existing Study / Deck / editor test passes unchanged with the default (no-op) test client | unit |
| **No visible impact (QA)** | | |
| 30 | With the activity server unreachable (`LA_CARTE_API=mock`, `LA_CARTE_ACTIVITY_URL` = a closed port) and with it hung (a listener that accepts and never answers), the study flow (reveal → rate, 10 cycles) shows the same screens as with `LA_CARTE_ACTIVITY=off`: same elements, no alert or notice; screenshots match | UI |
| 31 | Same three runs: median tap-reveal → back visible and tap-rate → next card visible differ by under 50 ms from the `off` run | UI |
| 32 | Events arrive once the server is back: study 3 cards with the activity URL on a closed port, terminate the app, relaunch pointed at the live API; within 15 s `GET /activity` lists the `card_shown`, `answer_revealed`, `rated` events of both sessions, each once, with the app's version/build and the device zone | UI (`scripts/e2e.sh`) |

## Screens & states
No new screen, no visible change. QA captures, in light mode only (the point is identity, not theme):
`study-front-activity-down`, `study-revealed-activity-down`, `study-front-activity-off`,
`study-revealed-activity-off` (for AC 30), and records the timings of AC 31 in the report.

## TCA shape (iOS)

### New module `ActivityClient` (`Sources/ActivityClient/`, + `Tests/ActivityClientTests`)
Depends on `APIClient` (models, URL/token resolution), `Dependencies`. No ComposableArchitecture.

```swift
@DependencyClient
public struct ActivityClient: Sendable {
  /// Fire and forget: returns at once, never throws, never blocks on I/O.
  public var log: @Sendable (_ activity: Activity) -> Void = { _ in }
  /// The time durations are measured with.
  public var now: @Sendable () -> Date = { Date() }
}

public enum Activity: Equatable, Sendable {
  case appForeground, appBackground
  case queueFetched(count: Int, due: Int, new: Int, total: Int, nextDue: Date?)
  case cardShown(cardID: Card.ID, noteID: Note.ID, type: NoteType, prompt: [String])
  case answerRevealed(cardID: Card.ID, msSinceShown: Int?)
  case rated(cardID: Card.ID, rating: Rating, input: RatingInput, msToReveal: Int?, msToRate: Int?)
  case reportSent(cardID: Card.ID, reason: ReportReason)
  case photoFailed(cardID: Card.ID, side: Side)
  case noteCreated(noteID: Note.ID, type: NoteType, directions: Int)
  case noteEdited(noteID: Note.ID, cardID: Card.ID?, source: EditSource)
  case noteDeleted(noteID: Note.ID)
  case deckLoaded(count: Int, query: Bool)
  case apiError(request: APIRequest, cardID: Card.ID?, status: Int, error: String)
}
```
- `liveValue`: an `ActivityLog` actor owning the buffer file and the uploader (decisions 4–8). `log` stamps `id`,
  `at`, `tz`, `session`, version/build/os synchronously, then `yield`s to the actor's stream. The actor is created
  lazily on the first `log` and flushes once at creation. It sends through `APIClient.live(baseURL:token:load:)`
  built with the activity `URLSession` (same URL/token resolution as the app; `LA_CARTE_ACTIVITY_URL` overrides the
  URL, for QA). The actor takes `send`, the file URL, a clock and the cap as init parameters so AC 12–18 test it
  directly.
- `testValue`: **no-op** (an explicit exception to "unimplemented test values", see `docs/tca-conventions.md`),
  so features that log don't force every existing test to stub it.
- `static func recording() -> (ActivityClient, LockIsolated<[Activity]>)`: for TestStore assertions.
- `previewValue`: no-op.

### `APIClient` change
- `sendActivity: @Sendable (_ events: [ActivityEvent]) async throws -> Void` → `POST /activity`. 2xx returns; any
  other status throws `APIError` (the actor applies decision 7). In-memory client: no-op success.
- `ActivityEvent` (`Models.swift`): the wire envelope, `Encodable` with explicit snake_case `CodingKeys` and the
  `at` format of AC 19 (`data` as `[String: JSONValue]` or an equivalent small encodable enum).

### Features
- `StudyFeature`, `DeckFeature`, `NoteEditorFeature` add `@Dependency(\.activity) var activity`.
- Keep logging out of the core logic: each feature appends one trailing `Reduce` after its core reducer that maps
  `(action, state)` to `Activity?` and returns `.run { [activity] _ in activity.log(event) }` (or `.none`).
  `card_shown` fits `.onChange(of: { $0.phase == .studying ? $0.cards.first?.id : nil })`.
- Study state gains an `ActivityTrail` (`shownAt`, `revealedAt`, what was already in flight), set by the trailing
  reducer and read for durations. Its `==` always returns `true` on purpose: it is bookkeeping for the log, so
  existing exhaustive `TestStore` tests don't have to assert it and logging never changes the state they compare.
  No new actions, no delegates, no parent changes. `AppFeature` unchanged.
- Durations use `ActivityClient.now`, not `@Dependency(\.date)`: its `testValue` is fixed, so features that log
  don't force every existing test to override `date`.
- `session`: one per launch and one per later return to the foreground; the launch's own first `app_foreground`
  keeps the launch session, so one launch is one session.
- Package: new `ActivityClient` target + test target; the three features depend on it.

## API / MCP changes

### Table `activityevent` (`models.py`, new: `create_all`, no `_migrate` step, no backup, like 025)
| Field | Type | Notes |
|---|---|---|
| `id` | UUID | primary key, from the client |
| `kind` | str | `^[a-z][a-z_]{0,39}$`, indexed |
| `at` | UTC datetime | device time converted to UTC, indexed |
| `tz` | str | IANA zone, ≤ 64 |
| `session` | UUID | |
| `card_id` | UUID \| null | no foreign key, indexed |
| `app_version`, `build`, `os` | str | ≤ 32 each |
| `data` | JSON | object, ≤ 4 KB serialized |
| `received_at` | UTC datetime | server clock |

### `deck.py`
- `ACTIVITY_RETENTION = timedelta(days=90)`, `ACTIVITY_BATCH_MAX = 500`, `ACTIVITY_LIST_MAX = 1000`.
- `ingest_activity(session, events: list[dict], now=None) -> ActivityIngest` validates each with
  `ActivityEventIn.model_validate`, inserts valid ones in one `INSERT … ON CONFLICT(id) DO NOTHING`.
- `list_activity(session, since=None, until=None, card_id=None, kind=None, session_id=None, limit=100)
  -> list[ActivityEventRead]`, newest first.
- `prune_activity(session, now=None) -> int`, called once by `create_app` at startup.

### REST
`POST /activity`
```json
{"events": [
  {"id": "6f1c…", "kind": "rated", "at": "2026-11-25T10:14:03.120+01:00", "tz": "Europe/Paris",
   "session": "a2d4…", "app_version": "1.0", "build": "42", "os": "iOS 26.1", "card_id": "9b3e…",
   "data": {"rating": "good", "input": "drag", "ms_to_reveal": 1830, "ms_to_rate": 2410}}
]}
```
→ 200 `{"stored": 1, "duplicates": 0, "rejected": 0}`; over 500 events → 413 `{"detail": "At most 500 events per
request."}`. `events` must be a list (else 422); each element is validated on its own (decision 12).

`GET /activity?since=&until=&card_id=&kind=&session=&limit=` → `[ActivityEventRead]` newest first.
`ActivityEventRead` = `{id, kind, at, local_at, tz, session, card_id, app_version, build, os, data, received_at}`.
(Read endpoint: for QA's AC 32 and the developer's curl; the app never calls it.)

### MCP (`mcp_server.py`, new "Activity (spec 029)" section after Feedback)
`activity_log(since: datetime | None = None, until: datetime | None = None, card_id: UUID | None = None,
kind: str | None = None, session: UUID | None = None, limit: int = 100) -> list[ActivityEventRead]`.
Docstring: "What the user did in the app, newest first: cards shown, answers revealed, ratings (with time to reveal
and to rate), notes created / edited / deleted, reports, app foreground / background, queue fetches (how many cards
were served) and errors (failed requests, broken photos). `at` is UTC, `local_at` the user's local time. Use it to
understand feedback or a report: query around its `created_at` (e.g. 15 minutes before to 5 after) or by `card_id`.
Read-only; kept 90 days; events reach the server lazily, so the last minute may be missing."

Additions:
- `list_feedback` docstring: "+ To see what the user was doing, call `activity_log` around each item's `created_at`."
- `list_reports` docstring: "+ `activity_log(card_id=…)` shows how the card was shown and rated."
- `INSTRUCTIONS`, one line: "Activity. `activity_log` lists what the user did in the app (dated); read it when
  handling feedback or reports. It holds no card text."

## Accessibility identifiers
None new.

## Docs updated in this change
- `docs/architecture.md`: `ActivityClient` module + dependency rule, `activityevent` table, REST rows, MCP tool,
  retention, runtime variables `LA_CARTE_ACTIVITY`, `LA_CARTE_ACTIVITY_URL`.
- `docs/tca-conventions.md`: the no-op `testValue` exception for fire-and-forget clients.

## Out of scope
- An offline queue for ratings, reports or edits (backlog #9 stays deferred): only activity events are buffered.
- Any UI: no log viewer, no Settings toggle, no "sending…" indicator; no feedback sending from the app.
- Logging agent (MCP) actions, widget events, navigation / sheet opens, typing, Ask AI, every request's latency.
- Crash reports, performance traces, device model or any identifier beyond the per-launch session.
- Aggregates, dashboards, exports, a `prune` MCP tool, a retention setting.
- Background `URLSession` / `BGTaskScheduler` uploads: the next foreground is soon enough.
