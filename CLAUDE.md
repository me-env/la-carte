# la-carte

A minimalist flashcard app: **one deck, no login, spaced repetition (FSRS)**, plus an **MCP server**
so any agent can say "add these words to my deck". Monorepo:

| Path | What | Stack |
|---|---|---|
| `api/` | Source of truth: cards, scheduling, REST for the app, MCP for agents | Python 3.13, FastAPI, SQLModel/SQLite, `fsrs`, `mcp` 2.x, uv |
| `ios/` | The app: thin Xcode shell + `LaCarteKit` Swift package (all code lives there) | Swift 6, SwiftUI, TCA 1.26, iOS 26+ |
| `docs/` | Architecture, conventions, design system, specs | — |
| `qa/` | QA reports + exported UI-test screenshots | — |
| `scripts/` | The only way to build/test (agents: use these, don't improvise xcodebuild) | bash |
| `ci/`, `.github/` | CI + Ad Hoc .ipa for the iPhone (see `docs/release.md`) | GitHub Actions |
| `docker-compose.yml`, `api/Dockerfile` | Production API on Dokploy (see `docs/deploy.md`) | Docker Compose |

## Commands

```bash
scripts/api-test.sh          # ruff + pytest
scripts/api-dev.sh           # API on :8000 (REST + /mcp), auto-reload
scripts/ios-build.sh         # build app for simulator
scripts/ios-test.sh          # LaCarteKit unit tests (TestStore)
scripts/ios-ui-test.sh <run> # XCUITest (mock API) → qa/screenshots/<run>/
scripts/e2e.sh <run>         # fresh API + seeded deck → live UI tests → qa/screenshots/<run>/
scripts/ios-adhoc.sh         # signed Ad Hoc .ipa (same steps as CI)
scripts/ios-install-device.sh [ipa]  # install latest CI .ipa (or a local one) on the iPhone
```
Simulator defaults: `iPhone 17 Pro`, latest iOS (27). Override with `SIMULATOR=… OS=…`.

## How work gets done (agent team)

The main session is the **manager**: it talks to the user, keeps the backlog
(`docs/specs/backlog.md`), and delegates. It does not write feature code itself. It commits finished
work without asking; it still asks the user before pushing tags, setting secrets, touching the Apple
account or installing on the iPhone. No CodeGraph in this repo: don't offer to initialize it.

| Agent | Owns | Never |
|---|---|---|
| `architect` | Specs in `docs/specs/`, API ↔ app contracts, architecture docs | Writes feature code |
| `ios-engineer` | `ios/LaCarteKit/**`, `ios/LaCarte/**` + unit tests | Touches `LaCarteUITests/`, `api/` |
| `api-engineer` | `api/**` (REST, MCP, scheduling) + pytest | Touches `ios/` |
| `code-reviewer` | Read-only review for simplicity/clarity/conventions | Edits code |
| `qa-validator` | **Independent** E2E: `ios/LaCarteUITests/**`, `qa/**`, screenshots, verdict | Edits app or API code |
| `release-engineer` | CI, signing, Ad Hoc builds, installing on the iPhone (`ci/`, `.github/`) | Changes features; touches the Apple account/repo without the user's OK |
| `design-lead` | Design system + brand: native feel (Apple components first), `docs/design-system.md`, `DesignSystem` module, dynamic SwiftUI logo, app icon, brand kit (`docs/design/brand*`) for marketing | Edits feature code (writes design notes into specs instead) |
| `instructions-keeper` | Sanity of all agent instructions (`CLAUDE.md`s, `.claude/agents/`, skills, docs agents read): correct, useful, not duplicated, no slop | Touches product code; weakens safety rules |
| `secrets-guard` | Read-only check that no credentials or private data reach the public repo (tree + history) | Edits files; prints secret values |
| `marketing` | Demo deck content, demo videos (app + widget, agent-adds-cards via MCP), README visuals (`docs/marketing/`, `marketing/`) | Touches app/API code; shows real URLs, tokens or personal data |

The repo is public: run `secrets-guard` before every push, and whenever CI, signing, deploy or config files change.

**Every agent can spawn sub-agents** (`Agent` tool), in parallel when the work is independent. Use them
for deep dives: research, reading many files, and especially to **verify that something really can't be
done** before saying so. Give a sub-agent a narrow brief and the files to read; you stay accountable for
its result.

**Asking the user for something** (only after that deep dive). One request at a time, each with:
1. **What** you want to do.
2. **Why you can't do it yourself**: what you tried or checked, and the concrete blocker (needs their
   Apple account / physical device / a secret / a UI only they can reach / their decision). "I didn't
   try" is not a reason.
3. **What they should do**: exact steps or the command to paste, and how you'll know it worked.

**English only**: app UI, sample and demo content, docs, commits, test fixtures.

**No macOS privacy prompts unless the user is at the Mac and said go:** no `xcrun devicectl`
(so no `scripts/ios-install-device.sh`), no ad-hoc `xcrun simctl io`/`ui`/`privacy`, no reading
`~/Library` or the Keychain. A blocked prompt stalls the whole run: use the repo scripts, and list
skipped checks as "left for the user".

Pipeline per feature — full detail in `docs/workflow.md`:
**spec (architect) → implement (ios/api engineer) → review (code-reviewer) → validate (qa-validator) → done.**
A feature is **not done** until `qa-validator` has written a PASS report with screenshots in `qa/reports/`.

## Non-negotiables

- **Simple and readable beats clever.** Smallest change that fully solves the spec. No speculative abstractions.
- iOS follows `docs/tca-conventions.md` (latest Point-Free practices). API follows `docs/architecture.md`.
- Visual work follows `docs/design-system.md`; tokens live in `ios/LaCarteKit/Sources/DesignSystem`.
- Any API contract change updates **both** sides in the same feature: `api/` models + `APIClient` + `DecodingTests`.
- Every interactive view element gets an `accessibilityIdentifier("<feature>.<element>")` (UI tests depend on it).
- Run the relevant `scripts/*` before reporting work as finished, and report failures honestly.
