# QA: 016a Ask about this card (copy + "Copied")

Verdict: **PASS**
Date: 2026-11-22 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-acb62b7c558f65dcb` (50ff9a7 + main 82df9d3)
Runs: `qa/screenshots/report/`, `qa/screenshots/015b-full/`
Commands: requested split run (016a tests ✅; the run's red is 015b bug 1), full suite ✅ for 016a tests,
`scripts/ios-test.sh` ✅ 215 passed. 016a has no live criterion; e2e results are in `015b-report-card.md`.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS: no title, "Ask about this card" (`study.report.ask`) first, then the five reasons in order (light + dark) | `report/study-ask-menu-{light,dark}.png` |
| 2 | PASS: "Copied" in `study.reportNotice` (counter hidden), `study.remaining` back after ~2 s. Pasteboard read inside the app (Paste into the New card front field) equals the spec template exactly, lowercase id, trailing `\n\n`: `"This is the card aaaaaaaa-0000-0000-0000-0000000000a1 in the La Carte flashcard app.\nQuestion: serendipity\nAnswer: finding something good without looking for it\n\n"` | `015b-full/study-ask-copied-light.png`, `report/study-ask-copied-dark.png`, `report/study-ask-pasted-light.png` |
| 3 | unit (green, `scripts/ios-test.sh`) | LaCarteKit tests |
| 4 | PASS: no request (stub saw no write), card stays revealed, ratings enabled, count unchanged | `testAsk_copiesCardText` |
| 5 | unit (green) | `StudyReportTests` |
| 6 | unit (green) | `StudyReportTests` |

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark
- [x] notice is the counter-slot meta text, no pink, no blue
- [x] circle buttons aligned
- [x] menu titles not truncated
- [ ] Dynamic Type: deferred
- Note (shared with 015b): the popover arrow covers part of the answer line while the menu is open.

## Bugs
None.
