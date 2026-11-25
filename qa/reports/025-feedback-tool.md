# QA: 025 Feedback to the developer (MCP)

Verdict: PASS
Date: 2026-11-25 · Commit: 5c4d100 (main) · API/MCP only: no simulator, no screenshots (spec: "Screens & states: None")
Commands: `scripts/api-test.sh` (✅ ruff + 247 passed), manual MCP walk over real streamable HTTP (✅)

## Method
Fresh API (`uv run la-carte-api`, the `scripts/e2e.sh` mechanics) on an OS-picked free port, scratch SQLite DB,
bearer token set. JSON-RPC `initialize` / `tools/list` / `tools/call` posted to `/mcp` with the token. Deck seeded with
2 cards (`greeting`, `gratitude`) via `POST /cards`. Server stopped at the end (no process left; DB dir held only
`qa.db` + `api.log`, no backup file).

## Evidence (tool calls, replies trimmed)
```
tools/list -> send_feedback, list_feedback, close_feedback present
  send_feedback.kind   = $ref FeedbackKind, default "other"
  list_feedback.status = anyOf(const "all", FeedbackStatus), default "open"
  send_feedback description mentions card reports: true

send_feedback(message="  bug: add_notes should accept tags  ", kind="bug")
  -> {id, kind:"bug", message:"bug: add_notes should accept tags", status:"open", resolution:null, created_at, closed_at:null}
send_feedback(... kind="confusing" | "missing" | "friction" | "other")  -> each OK, kind echoed, message trimmed
send_feedback(message="default kind")                -> kind:"other", status:"open"
send_feedback(message="x", kind="praise")            -> isError: "Input should be 'bug', 'confusing', 'missing', 'friction' or 'other'"
send_feedback(message="")                            -> isError: "`message` is required: what went wrong, or what's missing."
send_feedback(message="   \n  ")                     -> isError: same message
send_feedback(message=<2001 chars>)                  -> isError: "`message` is at most 2000 characters."
send_feedback(message="  "+<2000 chars>+"  ")        -> OK, stored length 2000

list_feedback()  -> 7 items, all open, oldest first (bug, confusing, missing, friction, other, other, other)
                    (rejected sends stored nothing: 5 kinds + default + 2000-char = 7)

close_feedback(<bug>, note="  fixed in 1.2  ") -> status:"done", resolution:"fixed in 1.2", closed_at set
close_feedback(<confusing>)                     -> status:"done", resolution:null, closed_at set
close_feedback(<missing>, note="   ")           -> status:"done", resolution:null
close_feedback("00000000-0000-0000-0000-000000000000") -> isError: "No feedback with id 00000000-0000-0000-0000-000000000000"
close_feedback(<bug>, note="again")             -> isError: "Feedback <bug id> is already done."
                                                   row unchanged: resolution "fixed in 1.2", same closed_at
close_feedback("not-a-uuid")                    -> isError: schema "Input should be a valid UUID"

list_feedback(status="open") -> 4: friction, other, other, other (all open)                      oldest first ✓
list_feedback(status="done") -> 3: bug "fixed in 1.2", confusing null, missing null (closed_at set) oldest first ✓
list_feedback(status="all")  -> 7: the 3 done then the 4 open, by created_at                       oldest first ✓
list_feedback(status="closed") -> isError: schema (Literal 'all' / 'open' | 'done')

Deck before vs after (list_cards, deck_stats, due_cards, REST GET /stats): identical [True, True, True, True]
GET /feedback -> 404, POST /feedback -> 404
sqlite feedback table: 7 rows, matches the replies above
```

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | send_feedback reply shape + row in `feedback` table (sqlite check); pytest |
| 2 | PASS | `"  … "` stored trimmed; pytest |
| 3 | PASS | all 5 kinds accepted and echoed; default `other` |
| 4 | PASS | empty and whitespace-only -> ToolError naming `message`; count stayed 7 |
| 5 | PASS | 2001 -> ToolError; 2000 (after trim) accepted |
| 6 | PASS | `kind="praise"` rejected by schema; nothing stored |
| 7 | PASS | `list_feedback()` only open, oldest first |
| 8 | PASS | `done` only done; `all` both, oldest first |
| 9 | PASS | close with note -> done, resolution trimmed, closed_at set; gone from open list |
| 10 | PASS | no note and blank note -> resolution null |
| 11 | PASS | unknown id and already done -> ToolError; row unchanged |
| 12 | PASS | list_cards / deck_stats / due_cards / GET /stats identical before and after |
| 13 | PASS | pytest (db test); fresh DB created the table, no backup file written |
| 14 | PASS | send_feedback description mentions card reports; INSTRUCTIONS paragraph covered by pytest |
| 15 | PASS | `/feedback` -> 404 (GET and POST) |

## Visual review
N/A: no UI in this spec.

## Bugs
None.

## Notes
- Schema rejections (bad kind/status/UUID) surface pydantic's raw validation text, as the spec allows ("rejected by
  the tool's schema, like `ReportOutcome`"). Readable enough for an LLM; not a bug.
