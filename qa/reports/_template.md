# QA: NNN Title

Verdict: PASS | FAIL
Date: YYYY-MM-DD · Simulator: iPhone 17 Pro / iOS 27
Runs: `qa/screenshots/NNN-mock/`, `qa/screenshots/NNN-e2e/`
Commands: `scripts/ios-ui-test.sh NNN-mock` (✅/❌), `scripts/e2e.sh NNN-e2e` (✅/❌), full suite (✅/❌)

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `NNN-mock/study-revealed-light.png` |

## Visual review (docs/design-system.md checklist)
- [ ] background edge to edge, light + dark
- [ ] nothing competes with the centered text, no default blue tint
- [ ] circle buttons aligned, 44pt
- [ ] long text wraps, no truncation
- [ ] Dynamic Type XL OK

## Bugs
1. **Title**: steps → expected → actual (screenshot)
