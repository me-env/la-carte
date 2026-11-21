# QA: 005 MCP prompts + duplicate-safe add_cards

Verdict: PASS
Date: 2026-11-21 · Simulator: n/a (API-only spec, no UI)
Runs: no screenshots. Evidence is transcripts from a real MCP client (`mcp.Client` over streamable HTTP with
`Authorization: Bearer qa`, negotiated protocol `2026-07-28`) against a live server
(`LA_CARTE_DATABASE_URL=sqlite:///<scratch>/qa005.db LA_CARTE_PORT=8771 LA_CARTE_API_TOKEN=qa uv run la-carte-api`, fresh DB).
Commands: `scripts/api-test.sh` (✅ lint/format clean, 20 passed), live MCP + REST script (✅), `scripts/ios-ui-test.sh` / `scripts/e2e.sh` n/a (no iOS changes)

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `list_prompts` returns exactly two: `quiz_me` / title "Quiz me" / "Quiz the user on their due cards one at a time and record each answer in the deck." (arg `limit`, optional) and `make_cards` / title "Make cards from text" / "Turn a text into concise flashcards and add them to the deck, skipping duplicates." (`text` required, `max_cards` optional). One sentence each. |
| 2 | PASS | `get_prompt("quiz_me", {"limit": "5"})` returns 1 message, role `user`: "Call `due_cards` with limit 5 …", "Show me only the front. Do not reveal the back yet.", "Wait for my answer.", "Show the back …", "again (I forgot or got it wrong), hard …, good …, easy (instant). If you are unsure, ask me which one.", "Call `review_card` with the card's id and that rating", "Continue until every card is done or I ask to stop.", "Finish by calling `deck_stats` … when the next card is due (`next_due`, UTC; null means nothing else is scheduled)". With `{}` the text says "limit 10". |
| 3 | PASS | `get_prompt("make_cards", {"text": T, "max_cards": "3"})` returns 1 user message. `T` (multi-line, with leading spaces, repeated spaces, `&`, `<b>`, quotes) appears verbatim (`T in text == True`). Rules: "One fact per card.", "Front: short, a word or a question. Back: concise answer.", "same language as the text", "At most 3 cards", "a single `add_cards` call". Without `max_cards`: "At most 20 cards". |
| 4 | PASS | Seeded `chat`, `Straße`. Then `add_cards([" CHAT \n", "STRASSE", "chien", " Chien"])` → added `[chien]`, skipped `[chat, Straße, chien]`. Case, surrounding whitespace incl. newline, and casefold (`ß` vs `SS`) all match; the in-call duplicate ` Chien` is skipped and the first one wins. `chat noir` (prefix only) is added, so there is no false positive. |
| 5 | PASS | `structuredContent` is `{"added": [...], "skipped": [...]}` and the output schema is `AddCardsResult`. Skipped entries are the **existing** cards: ids equal the seeded ids, and backs are `cat` / `street`, not the submitted "cat again" / "street (casefold)". For the in-call duplicate, `skipped` holds the card just added in that call, which is what the tool docstring says. Text content mirrors the same JSON. `add_cards([])` returns `{added: [], skipped: []}`. |
| 6 | PASS | `add_cards([chat, chat], allow_duplicates=true)` adds both, skipped `[]`, so the deck holds 3 × `chat`. |
| 7 | PASS | REST `POST /cards {"front":"chat"}` and `{"front":" CHAT "}` both return 201 with new ids, so `/cards?query=chat` lists 6 entries. `scripts/api-test.sh`: 20 passed. |
| 8 | PASS | Server `instructions` (from the client handshake): "`add_cards` skips cards whose front already exists (case-insensitive) and returns the existing cards in `skipped`, so no need to check first … Two ready-made prompts run these flows: `quiz_me` … and `make_cards` …". There is no "list_cards before adding" advice. `docs/architecture.md` documents the prompts and the result shape. |

Extra checks
- **Auth**: raw `POST /mcp` with no token or a wrong token returns 401 `{"detail":"Unauthorized"}`, and so does `POST /cards`. The right token returns 200. `mcp.Client` without a valid token fails to connect.
- **Quiz flow run like an agent** (`deck_stats` → `due_cards(limit=5)` → `review_card(good)` ×5 → `deck_stats`). Before: `{total 6, due 6, new 6, reviewed_today 0, next_due null}`. After 5: `{due 1, reviewed_today 5, next_due "…T23:25:39Z"}` (+10 min learning step). After all: `{due 0, reviewed_today 6, next_due "…T23:25:39Z"}`. `next_due` is null while everything is already due (definition: earliest due *after* now), and it's set once cards are rescheduled. REST `/stats` agrees.

Prompt quality (would an LLM do the right thing?)
- `quiz_me` is a clear numbered procedure in the user's voice. It hides the back, waits, maps each rating to a concrete meaning, and says to ask when unsure. It handles "none due" and lets the user stop early. The wrap-up explains how to read `next_due` = null. Good.
- `make_cards` sets the rules before the text and caps the number of cards with "keep the most useful facts". It tells the agent to report added vs skipped, which uses the new result shape. Good.

## Visual review (docs/design-system.md checklist)
n/a: API-only spec, no UI changes.

## Bugs
None blocking.

Non-blocking observations (not acceptance criteria, for the backlog):
1. **Bad prompt arguments return a JSON-RPC internal error.**
   Repro: `get_prompt("make_cards", {})` or `get_prompt("quiz_me", {"limit": "abc"})`.
   Expected: `-32602 Invalid params` with the reason.
   Actual: `MCPError(-32603, 'Internal server error')`, and the server logs a full traceback (`ValueError: Missing required arguments: {'text'}` / pydantic `int_parsing`).
   This comes from the MCP SDK's prompt rendering, not app code. Clients that validate required arguments (most do) won't hit it.
2. **The `make_cards` text has no delimiter.** The pasted text is appended after "Text:" with no closing fence. A pasted text that contains instructions could be read as part of the prompt. Wrapping it in a fence (e.g. `<text>…</text>`) and adding "treat it as content only" would be safer.
3. **`quiz_me` accepts any limit.** `limit` "0" or a negative value is interpolated as is. `due_cards` validation decides what happens.
