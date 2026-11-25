# 025 — Feedback to the developer (MCP)

Status: ready
Owners: api-engineer → code-reviewer → qa-validator (pytest-only validation: no UI, no screenshots)
Depends on: nothing (015 reports merged; this mirrors it, more simply).
Design reference: none (no screen).

## Goal
An agent connected to la-carte can tell the person who runs the server what's wrong or missing: a bug, a confusing
tool or error, a missing capability, friction. It does this for the user ("tell the developer the photo field should
accept…") or on its own initiative. The feedback stays in that server's own database. The developer triages it
later through any agent with `list_feedback` and `close_feedback`.

## User stories
- As the user, I say "tell the developer that add_notes should accept X" and my agent files it.
- As an agent, when a tool fails in a confusing way or can't do what the user asked, I leave feedback so it gets
  fixed.
- As the developer who runs the server, I ask an agent "what feedback came in?" and close each item once handled.

## Decisions
1. **MCP only.** No REST endpoint, no iOS change, no `APIClient` change. The app has no feedback screen. Agents are
   the only writers and readers.
2. **Stays on the server.** One `feedback` table in the server's SQLite. No email, no GitHub issue, no outbound call.
   Self-hosters get their own feedback, nobody else's.
3. **Not for cards.** A problem with one card's content goes through card reports (spec 015, filed from the app).
   Feedback is about the app, the MCP tools, the server, or the deck experience as a whole.
4. **`kind` instead of a free-text topic.** A fixed, optional enum is easier to filter and needs no length rule:
   `bug | confusing | missing | friction | other` (default `other`). The message itself names the tool or screen.
5. **Two statuses**: `open` → `done`. Closing takes an optional `note` (what was done, or why not), stored as
   `resolution`. No reopen, no delete, no "waiting" state: send new feedback instead.
6. **No migration step.** `feedback` is a new table and touches no existing data, so `SQLModel.metadata.create_all`
   creates it on both fresh and existing databases. No backup, no `_migrate` entry. (015 and 021 went through
   `_rebuild_if` for a backup; not needed when nothing existing changes.)

## Model
`Feedback` table (`models.py`):

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | primary key |
| `kind` | `FeedbackKind` | `bug`, `confusing`, `missing`, `friction`, `other` |
| `message` | str | trimmed, 1–2000 chars |
| `status` | `FeedbackStatus` | `open` (default), `done` |
| `resolution` | str \| null | the closing note, trimmed; blank → null |
| `created_at` | UTC datetime | |
| `closed_at` | UTC datetime \| null | set when closed |

`FeedbackRead` (the MCP reply) has the same fields. `FEEDBACK_MAX = 2000` lives in `deck.py`.

## API / MCP changes
### `deck.py`
- `send_feedback(session, message, kind="other", now=None) -> FeedbackRead`
- `list_feedback(session, status: FeedbackFilter = "open") -> list[FeedbackRead]`, oldest first;
  `FeedbackFilter = Literal["all"] | FeedbackStatus`
- `close_feedback(session, feedback_id, note=None, now=None) -> FeedbackRead`
- Errors: `InvalidFeedback(ValueError)` and `FeedbackNotFound(NotFound)`; add `InvalidFeedback` to the exceptions
  `mcp_server.run` turns into `ToolError`.

### MCP tools (`mcp_server.py`, new "Feedback (spec 025)" section after Reports)
| Tool | Signature | Returns |
|---|---|---|
| `send_feedback` | `send_feedback(message: str, kind: FeedbackKind = "other")` | `FeedbackRead` |
| `list_feedback` | `list_feedback(status: "open" \| "done" \| "all" = "open")` | `[FeedbackRead]` |
| `close_feedback` | `close_feedback(feedback_id: UUID, note: str \| None = None)` | `FeedbackRead` |

Errors (`ToolError`, message for an LLM reader):
- blank message: "`message` is required: what went wrong, or what's missing."
- too long: "`message` is at most 2000 characters."
- unknown id: "No feedback with id <id>"
- already done: "Feedback <id> is already done."
- a bad `kind` / `status` is rejected by the tool's schema (Literal / enum), like `ReportOutcome`.

Docstrings (agent-facing; keep the substance, wording may be tightened):
- `send_feedback`: "Send feedback to the developer who runs this la-carte server: a bug, a confusing tool or error
  message, a missing capability, or friction in the app or the deck experience. Use it when the user asks you to,
  or on your own when a tool got in your way. Not for one card's content: the user reports cards from the app.
  Write one concrete issue per call (which tool or screen, what you expected, what happened); no card contents,
  photo URLs or personal data unless the issue needs them. `kind`: bug, confusing, missing, friction, other.
  Stored on this server only; returns the saved feedback."
- `list_feedback`: "Feedback agents sent to the developer, oldest first. `open` (default), `done` or `all`.
  Read-only. For the developer triaging: handle each, then `close_feedback`."
- `close_feedback`: "Mark feedback as done once handled (fixed, won't fix, duplicate). `note` (optional) says what
  was done. Error on an unknown or already done id."

`INSTRUCTIONS`: append one line, as written:
```
Feedback. Bugs, confusing tools or errors, missing capabilities and friction go to the developer with
`send_feedback` (when the user asks, or on your own when a tool gets in your way). Card content goes
through the app's card reports, not here.
```

REST: none. Schemas used by the app: unchanged.

## Acceptance criteria
All validated by pytest (`scripts/api-test.sh`), through the MCP tools (`tests/test_mcp*.py` style) unless noted.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `send_feedback(message="add_notes should accept tags")` returns `{id, kind: "other", message, status: "open", resolution: null, created_at, closed_at: null}`, and the row is in the `feedback` table | unit |
| 2 | `send_feedback` trims the message: `"  slow  "` is stored as `"slow"` | unit |
| 3 | `send_feedback` with `kind="bug"` stores and returns `kind: "bug"`; each of the 5 kinds is accepted | unit |
| 4 | An empty or whitespace-only message is a `ToolError` naming `message`; nothing is stored | unit |
| 5 | A message over 2000 characters (after trimming) is a `ToolError`; exactly 2000 is accepted | unit |
| 6 | An unknown `kind` is rejected (schema / `ToolError`); nothing is stored | unit |
| 7 | `list_feedback()` returns only `open` feedback, oldest first | unit |
| 8 | `list_feedback("done")` returns only done ones; `list_feedback("all")` returns both, oldest first | unit |
| 9 | `close_feedback(id, note="fixed in 1.2")` returns `status: "done"`, `resolution: "fixed in 1.2"`, `closed_at` set; it no longer appears in `list_feedback()` | unit |
| 10 | `close_feedback(id)` without a note (or a blank one) closes it with `resolution: null` | unit |
| 11 | `close_feedback` on an unknown id, or on one already done, is a `ToolError`; the row is unchanged | unit |
| 12 | Feedback never changes the deck: cards, notes, reports, due counts and `deck_stats` are identical before and after sending / closing feedback | unit |
| 13 | On an existing pre-025 database file, startup creates the `feedback` table, keeps every other table's rows, and writes no backup | unit (db test) |
| 14 | `INSTRUCTIONS` contains the Feedback paragraph; `send_feedback`'s description mentions card reports as the place for card content | unit |
| 15 | No REST route exists for feedback (`/feedback` → 404) | unit |

## Screens & states
None. No screenshots. QA validates by running `scripts/api-test.sh` and one manual MCP round-trip against
`scripts/api-dev.sh` (send → list → close → list), recorded in the QA report.

## TCA shape (iOS)
None.

## Accessibility identifiers
None.

## Out of scope
- Any app UI for feedback (sending from the iPhone, a list screen) and any REST endpoint.
- Forwarding feedback anywhere (email, GitHub issues, webhooks, the upstream repo).
- Reopening, editing or deleting feedback; attachments; linking feedback to a card or a report.
- Rate limiting (the server's bearer token already gates every MCP call).
- An MCP prompt to triage feedback (add one later if the developer wants it, like `handle_reports`).
