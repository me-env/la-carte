# 005 — MCP prompts + duplicate-safe add_cards

Status: done
Owners: api-engineer
Depends on: 001's `next_due` (only for the quiz wrap-up line; can ship without it)
Design reference: none (API only)

## Goal
An agent connected to la-carte can run two ready-made flows, "Quiz me" and "Make cards from this text",
and adding cards no longer creates duplicates by accident. Covers backlog item 8.

## User stories
- As the user, in my agent I pick the "Quiz me" prompt and get quizzed on my due cards one at a time; my
  answers are recorded so the app's schedule stays in sync.
- As the user, I paste a text into "Make cards from text" and get concise cards added to my deck, without
  duplicating cards I already have.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `list_prompts` returns exactly `quiz_me` (title "Quiz me") and `make_cards` (title "Make cards from text"), each with a one-sentence description | pytest (in-process `Client`) |
| 2 | `get_prompt("quiz_me", {"limit": "5"})` returns one user message that tells the agent to: call `due_cards` with limit 5; show only the front; wait for the user's answer; then show the back; pick a rating (again = forgot, hard, good, easy) — asking the user when unsure; call `review_card`; continue until done; finish with `deck_stats` (mentioning `next_due`). `limit` is optional (default 10) | pytest (asserts the tool names and the limit appear in the text) |
| 3 | `get_prompt("make_cards", {"text": "…"})` returns one user message containing the text verbatim and the card rules: one fact per card, short front (word or question), concise back, same language as the text, at most `max_cards` cards (optional, default 20), then a single `add_cards` call | pytest |
| 4 | `add_cards` skips a card whose front equals an existing card's front, ignoring case (Unicode casefold) and surrounding whitespace; duplicates inside one call are skipped too (the first wins) | pytest (deck level) |
| 5 | `add_cards` returns `{"added": [Card], "skipped": [Card]}` where `skipped` lists the **existing** cards that matched, so the agent can tell the user or call `update_card` | pytest (MCP) |
| 6 | `add_cards(..., allow_duplicates=true)` adds everything (old behavior) | pytest |
| 7 | REST `POST /cards` is unchanged: it always adds (the user typed it on purpose) | pytest (existing tests stay green) |
| 8 | Server `INSTRUCTIONS` mention the two prompts and that `add_cards` skips duplicates (the "list_cards before adding" advice is removed) | review |

## API / MCP changes
**`deck.py`**: `add_cards(session, cards, now=None, skip_duplicates=False) -> AddCardsResult` (internal dataclass or
pydantic model with `added: list[Card]`, `skipped: list[Card]`). REST calls it with the default and uses `added[0]`.
Matching is done in Python over `(id, front)` of all cards (single small deck; no schema change).

**`models.py`**:
```python
class AddCardsResult(BaseModel):
    added: list[CardRead]
    skipped: list[CardRead]   # existing cards whose front matched
```

**MCP tool** (output shape changes from `list[Card]` to the object above):
```python
@mcp.tool()
def add_cards(cards: list[CardCreate], allow_duplicates: bool = False) -> AddCardsResult:
    """Add one or more cards. New cards are due immediately. A card whose front matches an existing
    card (case-insensitive) is skipped and the existing card is returned in `skipped`; pass
    allow_duplicates=true to add it anyway."""
```
Example result:
```json
{"added": [{"id": "…", "front": "chien", "back": "dog", "state": "new", "due": "…", "last_review": null, "created_at": "…", "updated_at": "…"}],
 "skipped": [{"id": "…", "front": "chat", "back": "cat", "...": "…"}]}
```

**MCP prompts** (`@mcp.prompt(title=…)` in `mcp_server.py`, each returning a single user message):
- `quiz_me(limit: int = 10)`
- `make_cards(text: str, max_cards: int = 20)`
Prompt arguments arrive as strings over MCP; test with string values.

REST: none. iOS: none.

## Docs
Update `docs/architecture.md` "MCP tools" with the prompts and the `add_cards` result (done with this spec).

## Out of scope
- Fuzzy / semantic duplicate detection, duplicate checks on the back.
- MCP resources, sampling, elicitation; a bulk REST endpoint.
