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
- Visual changes: `design-lead` annotates the spec with design notes before engineers start.
- Run `secrets-guard` before every push; only `[block]` items stop it.
- After any change to `.claude/agents/*.md` or a `CLAUDE.md`, run `instructions-keeper`.
- Spawn `qa-validator` fresh for each validation (no memory of implementation discussions).
- Never mark a spec `done` without a PASS report. Show the user the key screenshots.
- If two agents disagree (e.g. reviewer vs engineer), decide using the docs; if the docs are silent, ask the user, then update the docs.

## Definition of done

1. All acceptance criteria in the spec are met.
2. `scripts/ios-test.sh` and/or `scripts/api-test.sh` green.
3. `code-reviewer` approved.
4. `qa-validator` PASS: `scripts/ios-ui-test.sh` (mock, light + dark) and `scripts/e2e.sh` (live API) green,
   screenshots reviewed against `docs/design-system.md`, report committed in `qa/reports/`.
5. Spec status set to `done`.
