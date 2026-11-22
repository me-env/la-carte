# Video B: "ask an agent to add cards" (storyboard + script)

Target 35–40 s, 1920×1080, no audio, captions bottom-centre (same style as `app-demo.md`). Left: a terminal
running real Claude Code connected to a **local throwaway API** over MCP. Right: the phone. The MCP calls and
their results are real; dead time while the model thinks is cut, never faked (`video-tools.md`).

## Setup (off camera)

```bash
TMP=$(mktemp -d)
LA_CARTE_DATABASE_URL="sqlite:///$TMP/demo.db" LA_CARTE_API_TOKEN=demo-token scripts/api-dev.sh &
marketing/seed-demo.sh                       # demo deck → "8 to review"
```

Terminal (inside VHS `Hide`/`Show`): `cd` into a neutral empty dir (no username in the prompt or path),
a demo `CLAUDE_CONFIG_DIR` whose header shows no email or org, then

```bash
claude mcp add --transport http la-carte http://127.0.0.1:8000/mcp --header "Authorization: Bearer demo-token"
```

and pre-allow `mcp__la-carte__add_cards`, `mcp__la-carte__add_people`, `mcp__la-carte__list_cards` so no
permission dialog interrupts the take. Font: SF Mono 22, light theme background `#F9FAF5`, ink `#1C1C1C`.

## Shot list

| # | s | Left: terminal | Right: phone | Caption |
|---|---|---|---|---|
| 1 | 3 | Claude Code prompt, empty | Study, **petrichor**, "8 to review" | Your agent can use your deck |
| 2 | 5 | Types `Add these to my deck: aurora, zenith, solace` ↵ | (still) | Just ask |
| 3 | 7 | Claude checks `list_cards` for duplicates, then calls `add_cards`; replies "Added 3 cards: aurora (dawn light), zenith (highest point), solace (comfort)" | (still) | It adds them over MCP |
| 4 | 6 | (frozen, dimmed 40%) | Pull to refresh on Study: count goes **8 → 11 to review** | There they are |
| 5 | 5 | Types `Also add Nora Vale, she runs the corner bakery` ↵ → `add_people` (no photo: the photo field is left empty on camera) | (still) | People too |
| 6 | 5 | (frozen) | Open the deck: Nora Vale's row and the three new words on top | Cards and people, in one deck |
| 7 | 4 | Types `Any reported cards?` → `list_reports` shows "Largest planet? · This is wrong" → `update_card` sets **Jupiter** | (still) | Reported cards get fixed |
| 8 | 4 | End card (full frame): `claude mcp add --transport http la-carte https://deck.example.com/mcp` + `github.com/me-env/la-carte` | | Any MCP agent. Your own server |

Shot 7 needs a report first: seed one off camera (`POST /cards/{id}/report` with `{"reason":"wrong"}` on a
"Largest planet? / Saturn" card added by the setup script), or drop the shot.

## Phone side without screen recording

The phone half can come from `MarketingUITests` instead of `recordVideo`: a test pointed at the throwaway API
(`LA_CARTE_API_URL=http://127.0.0.1:8000 LA_CARTE_API_TOKEN=demo-token`) that snapshots before and after each
terminal step, then `build-demo.py`-style crossfades. The terminal half needs VHS (`video-tools.md`); its tape
file goes in `marketing/agent-video.tape` when recorded.

## Checks before publishing

- `secrets-guard` reviews every terminal frame and the tape: no email, org, home path, real URL or token.
- The only server shown is `127.0.0.1` (setup) and `deck.example.com` (end card).
