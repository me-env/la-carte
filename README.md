# la carte

One flashcard deck. Spaced repetition. No account. Any agent can add to it over MCP.

- `api/`: FastAPI + FSRS + MCP server (`/mcp`)
- `ios/`: SwiftUI + The Composable Architecture
- `docs/`: architecture, conventions, design system, specs
- Built by a team of Claude Code agents: see `CLAUDE.md` and `docs/workflow.md`.

## Quick start

```bash
scripts/api-dev.sh                      # API on http://127.0.0.1:8000
open ios/LaCarte.xcodeproj              # run the LaCarte scheme
```

Add the deck to Claude Code:
```bash
claude mcp add --transport http la-carte http://127.0.0.1:8000/mcp
```
When the server isn't local, set `LA_CARTE_API_TOKEN` on it and pass `--header "Authorization: Bearer …"`.

## Deploy and install

- API on a server (Dokploy, Docker Compose, HTTPS, backups): `docs/deploy.md`
- App on the iPhone (Ad Hoc .ipa): `docs/release.md`
