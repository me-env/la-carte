# QA: 017 #15 Answer alignment (answer aligns on its own lines)

Verdict: PASS
Date: 2026-11-28 · Simulator: iPhone 17 Pro / iOS 27 (CI)
Runs: `qa/screenshots/017-15/` (from CI UI run 46089120043, head 8bf36d9)
Commands: CI UI run 46089120043 (StudyAnswerAlignUITests, StudyLengthsUITests, StudyRevealLiftUITests,
`NotesUITests/testNotesStudy_personTextLayout`) ✅ · CI full run 46089123162: one failure, the unit test
`ScreenColorTests/questionStaysPut`, which predates this change and is being updated by ios-engineer (not a UI
criterion). No local runs: the Mac was hung, so all evidence comes from CI.
Reference: design-lead blind A/B, option A (user's choice), panels 2, 4 and 5.

## Acceptance criteria (#15)
| # | Result | Evidence |
|---|---|---|
| a | PASS: 4-line leading question with a 1-line answer. "The Peace of Westphalia" is centred on screen and does not start at the question's left edge. Matches reference panel 2. Asserted in the test (midX within 1 pt). | `017-15/study-answer-align-a-1line-back-light.png`, `…-dark.png` |
| b | PASS: same question with a 2-line answer. Both lines are centred ("…signed in Osnabrück / and Münster in 1648"). | `017-15/study-answer-align-b-2lines-back-light.png`, `…-dark.png` |
| c | PASS: same question with a 3-line answer. The answer is leading and starts at the question's left edge, within its width. Matches reference panel 4. | `017-15/study-answer-align-c-3lines-back-light.png`, `…-dark.png` |
| d | PASS: 1-line centred question ("mitochondria") with a 3-line answer. The answer is leading at the column edge. Matches reference panel 5. | `017-15/study-answer-align-d-shortq-3lines-back-light.png`, `…-dark.png` |
| e | PASS: the question doesn't move on reveal. In (a) the question's first line sits at the same y on the front and back screens, and the frame is asserted in the test. StudyRevealLiftUITests (#13, #14) is green in the same run. | `017-15/study-answer-align-a-front-light.png` vs `…-a-1line-back-light.png` |
| f | PASS: person cards are unchanged. Name and description stay centred under the photo. NotesUITests person layout is green. | `017-15/study-person-long-description-prompt-revealed-dark.png`, `study-person-*-revealed-*.png` |
| unit | Not a UI criterion. The `answerAlignment` rule lives in `StudyTextLayoutTests` (engineer's suite), which wasn't re-run locally here. | — |

The `StudyLengthsUITests` baseline (Westphalia long card, now centred) is green: `017-15/study-lengths-long-back-light.png`.

## Visual review (docs/design-system.md checklist)
- [x] Background runs edge to edge, light and dark
- [x] Nothing competes with the text, and there's no default blue tint
- [x] Circle buttons aligned, 44 pt
- [x] Long text wraps with no truncation (3-line answers wrap cleanly within the column)
- [ ] Dynamic Type XL: deferred (no accessibility checks for now)

## Bugs
None.
