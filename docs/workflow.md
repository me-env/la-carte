# Agent workflow

The manager (main Claude session) runs this loop for every backlog item. Each step is a separate
agent with its own context, so the hand-off artifact (spec, diff, report) must be self-contained.

```
 user ──► manager ──► architect ──► spec in docs/specs/NNN-name.md  (status: ready)
                         │
                         ├──► ios-engineer ─┐  (in parallel when the spec touches both sides;
                         └──► api-engineer ─┤   api first when the contract changes)
                                            ▼
                                     code-reviewer ── changes requested ──► back to engineer
                                            │ approved
                                            ▼
                                     qa-validator ── FAIL ──► back to engineer (report = bug list)
                                            │ PASS
                                            ▼
                         manager: spec status → done, summarize to user with screenshots
```

## Hand-offs

| From → To | Artifact | Must contain |
|---|---|---|
| manager → architect | user request | goal, constraints, what's out of scope |
| architect → engineers | `docs/specs/NNN-*.md` | user stories, acceptance criteria (numbered, testable), screens, API contract, accessibility ids |
| engineer → reviewer | the diff (`git diff`) + spec path | which acceptance criteria are covered by which unit tests |
| reviewer → manager | review verdict | `APPROVED` or `CHANGES REQUESTED` with file:line items |
| manager → qa-validator | **spec path only** | Not the engineer's notes: QA judges the product against the spec, independently |
| qa-validator → manager | `qa/reports/NNN-*.md` | per-criterion PASS/FAIL, screenshot paths, bugs with repro |

## Rules for the manager

- One feature in flight per engineer. Keep specs small (one screen or one flow).
- Visual changes: `design-lead` annotates the spec with design notes before engineers start. Every design-lead visual goes to `design-critic` (compares with the reference app) and iterates until SHOW TO USER, before the user sees it. Changes to an existing design are judged blind A/B against the current one (`.claude/agents/design-lead.md`); the report must include both scores.
- Run `secrets-guard` before every push; only `[block]` items stop it.
- After any change to `.claude/agents/*.md` or a `CLAUDE.md`, run `instructions-keeper`.
- Spawn `qa-validator` fresh for each validation (no memory of implementation discussions).
- Never mark a spec `done` without a PASS report. Show the user the key screenshots (full screens, see below).
- If two agents disagree (e.g. reviewer vs engineer), decide using the docs; if the docs are silent, ask the user, then update the docs.

## Visuals shown for judgment

Applies to renders opened for the user, design-critic inputs (blind A/B pairs too) and QA screenshots behind a verdict.
- Show the **whole device screen** at its real aspect ratio: status bar, top bar and bottom controls. Never a crop
  of one region. Study renders have no status bar or glass, so a screen verdict uses the UI-test screenshot.
- A zoomed detail (`image-ops.py crop --zoom`) only as an extra next to the full screen, never instead of it.
- Comparisons: full screens side by side at the same scale (`image-ops.py montage`).
- Commits: no Vyst or Apple app icons; the app's own screens (status bar included) are fine. Vyst/Apple reference
  screens stay local and uncommitted, but are still shown full screen.

## Definition of done

1. All acceptance criteria in the spec are met.
2. `scripts/ios-test.sh` and/or `scripts/api-test.sh` green.
3. `code-reviewer` approved.
4. `qa-validator` PASS: `scripts/ios-ui-test.sh` (mock, light + dark) and `scripts/e2e.sh` (live API) green,
   screenshots reviewed against `docs/design-system.md`, report committed in `qa/reports/`.
5. Spec status set to `done`.
