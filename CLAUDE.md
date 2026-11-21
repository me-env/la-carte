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
| `ci/`, `.github/` | CI (`docs/ci-cd.md`) + Ad Hoc .ipa for the iPhone (`docs/release.md`) | GitHub Actions |
| `docker-compose.yml`, `api/Dockerfile` | Production API on Dokploy (see `docs/deploy.md`) | Docker Compose |

## Commands

```bash
scripts/api-test.sh          # ruff + pytest
scripts/api-dev.sh           # API on :8000 (REST + /mcp), auto-reload
scripts/ios-build.sh         # build app for simulator
scripts/ios-test.sh          # LaCarteKit unit tests (TestStore)
scripts/ios-ui-test.sh <run> # XCUITest (mock API) → qa/screenshots/<run>/
scripts/e2e.sh <run>         # fresh API + seeded deck → live UI tests → qa/screenshots/<run>/
uv run scripts/design-review.py <render> --home  # measured logo/visual review (design-critic gates on it)
scripts/ios-adhoc.sh         # signed Ad Hoc .ipa (same steps as CI)
scripts/ios-install-device.sh [ipa]  # install latest CI .ipa (or a local one) on the iPhone
```
Simulator defaults: `iPhone 17 Pro`, latest iOS (27). Override with `SIMULATOR=… OS=…`.
The iOS scripts take the build/simulator locks themselves: just run them (set `LACARTE_AGENT=<you>`),
never poll `pgrep` or sleep-wait. What runs in parallel: `docs/dev-velocity.md`.

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
| `release-engineer` | Signing, Ad Hoc builds (`adhoc.yml`, signing `ci/` scripts), installing on the iPhone | Changes features; touches the Apple account/repo without the user's OK |
| `design-lead` | Design system + brand: native feel (Apple components first), `docs/design-system.md`, `DesignSystem` module, dynamic SwiftUI logo, app icon, brand kit (`docs/design/brand*`) for marketing | Edits feature code (writes design notes into specs instead) |
| `design-critic` | Independent judge of design-lead's visuals (logo, icon, screens) against the reference app (Vyst) and Apple apps; feedback to design-lead until it's good enough to show the user | Designs or edits files |
| `dev-velocity` | Parallel agents don't block each other: build/simulator lock, per-agent clones, worktrees, disk; `docs/dev-velocity.md` | Skips tests or weakens safety to go faster |
| `cicd-lead` | CI/CD: GitHub Actions pipelines, test gating, API deploy (Dokploy) only after tests pass, fast feedback; `docs/ci-cd.md` | Signing/Ad Hoc/device installs (release-engineer) |
| `tooling-lead` | Audits the team's tools/processes one by one (`scripts/`, `ci/`, test helpers, render/video pipelines), researches better options, proposes to the owner, delegates agreed changes; keeps `docs/tooling.md` | Implements tooling itself; changes product code |
| `tooling-implementer` | Implements one agreed tooling change from tooling-lead's brief; reports to the owner and tooling-lead | Changes product features |
| `instructions-keeper` | Sanity of all agent instructions (`CLAUDE.md`s, `.claude/agents/`, skills, docs agents read): correct, useful, not duplicated, no slop | Touches product code; weakens safety rules |
| `secrets-guard` | Read-only check that no credentials or private data reach the public repo (tree + history) | Edits files; prints secret values |
| `marketing` | Demo deck content, demo videos (app + widget, agent-adds-cards via MCP), README visuals (`docs/marketing/`, `marketing/`) | Touches app/API code; shows real URLs, tokens or personal data |

`scripts/` owners: dev-velocity `_ios-env.sh` `_lock.sh` `ios-build.sh` `ios-test.sh` · qa-validator `ios-ui-test.sh`
`e2e.sh` (lock/scratch mechanics agreed with dev-velocity) · api-engineer `api-*.sh` · release-engineer `ios-adhoc.sh`
`ios-install-device.sh` · tooling-lead `design-review.py` `brandkit.py` (render methods agreed with design-lead) ·
design-lead `fetch-design-refs.sh`.

The repo is public: run `secrets-guard` before every push, and whenever CI, signing, deploy or config files change.

**Every agent can spawn sub-agents** (`Agent` tool), in parallel when the work is independent. Use them
for deep dives: research, reading many files, and especially to **verify that something really can't be
done** before saying so. Give a sub-agent a narrow brief and the files to read; you stay accountable for
its result.

**Watch your context.** Every turn re-reads your whole context, so a bloated agent burns usage fast.
- Don't dump big outputs: pipe through `tail`/`grep`/`head`, read files by range, never `cat` logs or JSONL.
- Delegate heavy reading/research to sub-agents and keep only their conclusion.
- Long task? Compact when your context gets large (~150k tokens): summarise state into your notes/report,
  then continue from the summary. If you can't compact, finish the current step, report a short hand-off
  (what's done, what's next, file paths) and stop; the manager restarts a fresh agent from it.

**Clean up your shells.** Never wait with `pgrep -f <pattern>` (it matches your own loop and never ends)
or an unbounded `until` loop: wait for a run with ONE background command that exits when it ends (the harness wakes you; every wake re-reads your whole context, so no short re-armed polls), bound it with a timeout, prefer the scripts' locks, and kill any
background process you started (servers, watchers, pagers) before you report.

**Ask for better tooling.** If you're judging by eye, repeating manual steps, waiting on slow or flaky
tools, or lack a capability (a measurement, a reference, an MCP, a test hook), say so in your report under
`Tooling request:` (what's missing, what it costs you today, what would help). The manager routes it to
`tooling-lead`. Don't silently work around a missing tool.

**Asking the user for something**: only after that deep dive, and always through the
`asking-the-user` skill (`.claude/skills/asking-the-user/SKILL.md`): one request at a time, the smallest
reasonable action on their side, prefer requests that give you durable autonomy.

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
