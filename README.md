<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/design/brand/logo-dark.svg">
    <img src="docs/design/brand/logo-light.svg" width="96" height="96" alt="la carte logo">
  </picture>
</p>

<h1 align="center">la carte</h1>

<p align="center">One flashcard deck. Spaced repetition. No account. Any agent can add to it over MCP.</p>

<!-- Demo GIF (≤ 8 s, study flow) goes here once recorded: see docs/marketing/shot-list.md -->

## What it is

An iPhone app and a small server for one deck of flashcards. Open the app and you are already reviewing:
one card in the middle of the screen, tap to see the answer, rate how well you knew it. The server schedules
each card with [FSRS](https://github.com/open-spaced-repetition/py-fsrs), so it comes back just before you
would forget it.

## Why

Making cards is the chore that stops most people. la carte's server speaks
[MCP](https://modelcontextprotocol.io), so you can ask any agent, in the middle of whatever you are doing,
"add these to my deck", and the cards are on your phone the next time you look. The agent can also quiz you,
and its reviews count toward the same schedule.

## Features

- **Study first.** The app opens on the next due card. Again, Hard, Good, Easy. "All caught up" says when the
  next card is due.
- **One deck.** Search it, add and edit cards, swipe to delete. Pull to refresh after an agent adds cards.
- **Calm by design.** Light, dark, or forest theme. Large centered text, small round controls, Dynamic Type.
- **Agents built in.** MCP tools to add, find, edit and review cards, with duplicate-safe adding, plus two
  ready-made prompts: *Quiz me* and *Make cards from text*.
- **Yours.** Self-hosted: one SQLite file behind one token. No account, no tracking.
- **Home Screen widget** (in progress): cards to review and your study streak.

## Screenshots

<!-- Study · Deck · Forest theme · Widget: added from qa/screenshots once the launch takes are recorded -->

## Quick start

Requirements: [uv](https://docs.astral.sh/uv/) (Python 3.13) and Xcode with the iOS 26 SDK or later.

```bash
scripts/api-dev.sh                      # API on http://127.0.0.1:8000
open ios/LaCarte.xcodeproj              # run the LaCarte scheme on a simulator
```
In the app, open Settings and enter `http://127.0.0.1:8000` and any token (a local server started without
`LA_CARTE_API_TOKEN` doesn't check it).

Add the deck to Claude Code:
```bash
claude mcp add --transport http la-carte http://127.0.0.1:8000/mcp
```
Then ask: *"Add these to my deck: aurora, zenith, solace."*

When the server isn't local, set `LA_CARTE_API_TOKEN` on it and pass `--header "Authorization: Bearer …"`.

## Self-host

**API.** Any host with Docker:
```bash
echo "LA_CARTE_API_TOKEN=$(openssl rand -hex 32)" > .env   # keep this token, the app and agents need it
docker compose up -d --build                               # deck in the volume la-carte-data
```
Put it behind an HTTPS reverse proxy (the token must not travel over plain HTTP). Port 8000 is only
exposed on the Docker network: run the proxy there, or publish `127.0.0.1:8000:8000` for a proxy on the
host. Dokploy is one option: `docs/deploy.md`.

**App.** The simulator needs no Apple account: open `ios/LaCarte.xcodeproj` and run. On your iPhone
(paid Apple Developer account): copy `ios/Config/Signing.local.xcconfig.example` to
`Signing.local.xcconfig`, set your team ID and bundle ID prefix, register the phone on your team, then
`scripts/ios-adhoc.sh` and `scripts/ios-install-device.sh build/export/LaCarte.ipa` (`docs/release.md`).
In the app, open Settings and enter your server URL and token.

**Agents.** Any MCP client:
```bash
claude mcp add --transport http la-carte https://<your-host>/mcp --header "Authorization: Bearer <token>"
```

## What an agent can do

The server is at `/mcp` (streamable HTTP), next to the REST API the app uses.

| Tool | What it does |
|---|---|
| `add_cards` | Add one or more cards; skips fronts already in the deck (case-insensitive) |
| `list_cards` | List or search cards |
| `update_card`, `delete_card` | Fix or remove a card |
| `due_cards`, `review_card` | Study from the agent; reviews update the same schedule as the app |
| `deck_stats` | Totals, due now, next due card, streak |

Prompts: **Quiz me** (`quiz_me`), **Make cards from text** (`make_cards`), **Add people** (`add_people`) and **Handle reports** (`handle_reports`, also what a recurring report watcher runs). The server also tells agents to keep
cards minimal: a word or short question on the front, the shortest answer on the back.

## Docs

- API on a server (Dokploy, Docker Compose, HTTPS, backups): `docs/deploy.md`
- App on the iPhone (Ad Hoc .ipa): `docs/release.md`
- Architecture and API contract: `docs/architecture.md`
- Design system: `docs/design-system.md`

## How it's built

- `api/`: Python, FastAPI, SQLite, FSRS, MCP server
- `ios/`: SwiftUI and The Composable Architecture
- `docs/`: architecture, conventions, design system, specs

Built by a team of Claude Code agents (spec, implement, review, validate): see `CLAUDE.md` and
`docs/workflow.md`. Contributions follow the same rules and `scripts/`.

## License

MIT, see `LICENSE`.
