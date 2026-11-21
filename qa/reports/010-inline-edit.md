# QA: 010 Inline edit on the revealed card

## Final recheck 2026-11-21 (integrated branch, main merged): **PASS**
The swipe-down bug below is fixed (any focus loss commits, `.immediately` keyboard dismiss). `StudyEditUITests` 8/8 passed
(1 live skipped) in `UI_WORKERS=1 scripts/ios-ui-test.sh --split 3 final` (`qa/screenshots/final/study-edit-*`);
`testStudyEdit_appendToBack_liveAPI` passed in `scripts/e2e.sh final-e2e`. Inline edit stays off on person cards (014d #9:
unit). Branch-wide blockers are listed in the 014c report (unit tests don't compile after the merge).

---


Verdict: **FAIL** (1 bug: swiping the keyboard down no longer commits)
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27 · Code: `1ba2dad` (branch `worktree-agent-a49c6e2d8c3e3ec0b`, main merged)
Runs: `qa/screenshots/study-final/` (StudyEdit + Ratings + Study + Refresh), `qa/screenshots/study-edit-r1..r3/`
(StudyEdit x3, flake check), `qa/screenshots/study-edit-r4/` (final #5 / #6 / #13 tests), `qa/screenshots/study-final-e2e/`
Commands: `scripts/ios-ui-test.sh --split 4 study-final -only-testing:…/StudyEditUITests …/RatingsUITests
…/StudyUITests …/RefreshUITests` (❌ 30 passed, 3 failed: keyboard swipe, a stale test id since fixed, VoiceOver
since turned into a skip), `--split 4 study-edit-r{1,2,3} -only-testing:…/StudyEditUITests` (❌ each 7 passed,
2 failed: keyboard swipe + VoiceOver), `study-edit-r4` (❌ 1 passed, 1 failed: keyboard swipe; 1 skipped:
VoiceOver), `scripts/e2e.sh study-final-e2e` (✅ 7/7).

Tests (`ios/LaCarteUITests/StudyEditUITests.swift`) now use the two-button UI (011) and follow docs/testing.md "UI
tests test UI". Removed: the foreground-reload test (#10 is unit), the clear-on-rate/new-edit part of #9 (unit), the
caret-mid-text test (folded into `testStudyEdit_returnCommitsWithoutNewline`), the dark pass of #1, and the AX XL test
(the user deferred text-size tests).

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `testStudyEdit_doubleTapUnrevealedOnlyReveals`: `study-final/study-doubletap-unrevealed-light.png` |
| 2 | PASS | `testStudyEdit_editFront`: `study-editing-front-{light,dark}.png`, `study-editing-front-forest-light.png` |
| 3 | PASS | `testStudyEdit_editBackDone`: `study-editing-back-{light,dark}.png` |
| 4 | PASS | Done key → "a happy accident" at once, PATCH with front + back, two buttons back, "2 to review": `study-edited-light.png`. A newline is never saved: with the caret mid-text, Done ends the edit, and a typed "!\n" at the end commits "serendipity!" (`testStudyEdit_returnCommitsWithoutNewline`, green in all 4 runs) |
| 5 | **FAIL** | Tapping the empty card area commits (fixed), and so does tapping the other side's text (both green in `study-edit-r4`). **Swiping the keyboard down does not commit** (bug 1), 5 of 5 runs |
| 6 | PASS | `testStudyEdit_addCommitsThenOpensEditor`: PATCH sent, "New card" sheet opens, the back shows the edit after closing it. `study-edit-r4/study-edit-add-editor-light.png` |
| 7, 8, 10, 11, 12 | n/a (unit) | Per spec |
| 9 | PASS | Stub PATCH 500: old back, "Couldn't save the edit" centered in the counter slot, counter hidden, still on the card, two buttons. `study-edit-error-{light,dark}.png`. Clearing it is unit-tested |
| 13 | left for the user on device | Before reveal VoiceOver announces no action. On the revealed back, VoiceOver lists the actions Easy, Got it, Hard, Forgot, Edit (a synthesized swipe down walks them backwards, which is why the earlier run reached "Easy" first, as the engineer guessed). A synthesized double-tap under VoiceOver activates **no** custom action: neither "Edit" nor the control "Forgot", 4 of 4 runs. So XCUITest can't settle it. The test now skips with that message. Check on the iPhone: VoiceOver on, reveal, focus the back, swipe up/down to "Edit", double-tap → the field opens, labeled "Back" |
| 14 | PASS | Same font, color and centering, no chrome, pink caret: `study-editing-front-forest-light.png`, `study-editing-long-light.png`. No layout shift (asserted, ±2pt). Haptic: device check |
| 15 | PASS (long text) / deferred (AX XL) | 210-char back wraps in 5 lines, centered, above the keyboard: `study-editing-long-light.png`. AX XL deferred by the user |
| 16 | PASS | `testStudyEdit_appendToBack_liveAPI`: "hello" → "hello!", `GET /cards` shows it, restored. `study-final-e2e/study-edit-live-light.png` |

**Keyboard drop (previous bug 4):** not seen again. 5 StudyEdit runs (about 40 edit starts, each asserting the
keyboard is up and then pressing Done) plus the e2e run, all fine. Considered fixed.

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light, dark, forest
- [x] nothing competes with the centered text, and the counter is hidden while editing. The only pink is the caret.
  The keyboard's blue Done key is the system's
- [x] circle buttons aligned, 44pt, reachable while editing
- [x] long text wraps, no truncation
- [ ] Dynamic Type XL: deferred (user rule)

## Bugs
1. **Swiping the keyboard down doesn't end the edit (#5).** Mock or stub deck → reveal → double-tap `study.front` →
   type → drag from the middle of `study.back` down into the keyboard (to y = 98% of the screen), then a second drag
   from the empty card area just above the keyboard. Expected: the keyboard goes away, the edit commits (PATCH,
   buttons back). Actual: the keyboard stays up, the field stays focused, no PATCH
   (`study-edit-r4/study-edit-swipe-still-editing-light.png`). 5 of 5 runs on 1ba2dad, but it passed on 61b03be with
   the same gesture. Suspects: the 011 `HorizontalPan` or the new `SpatialTapGesture` on the card's scroll view
   taking the pan from `.scrollDismissesKeyboard(.interactively)`. Test:
   `testStudyEdit_commitByTapOutsideAndKeyboardSwipe` (last section).

Tooling request: XCUITest still can't perform a custom accessibility action. #13 (and 011 #17) need a device check by
hand each time. A DEBUG launch argument that logs the received actions would let QA close them unattended.
