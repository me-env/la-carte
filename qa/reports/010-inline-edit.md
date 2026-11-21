# QA: 010 Inline edit on the revealed card

Verdict: **FAIL** (4 bugs: #5 tap outside, Done with the caret mid-text, #13 VoiceOver "Edit", keyboard drops while editing)
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27 · Code: `daf6b4d` (branch `worktree-agent-af306c429b4830a9e`)
Runs: `qa/screenshots/010-mock/` (full suite), `qa/screenshots/010-mock-final/` (StudyEditUITests on daf6b4d),
`qa/screenshots/010-mock-dev/` (first pass on 61b03be), `qa/screenshots/010-e2e/`
Commands: full suite `scripts/ios-ui-test.sh 010-mock` (❌: 76 passed, 4 failed, all in StudyEditUITests; no
regression in other suites), `-only-testing:LaCarteUITests/StudyEditUITests` (❌ same failures),
`scripts/e2e.sh 010-e2e` (❌: the 6 earlier live tests pass and the deck stays as seeded; `testStudyEdit_appendToBack_liveAPI` fails on bug 4)

Tests: `ios/LaCarteUITests/StudyEditUITests.swift` (new). `scripts/e2e.sh` runs
`testStudyEdit_appendToBack_liveAPI` before 001's live flow (spec's `bonjour` = the seeded `greeting`/`hello`).

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `testStudyEdit_doubleTapUnrevealedOnlyReveals`: double-tap on the unrevealed front reveals, no field, no keyboard. `010-mock-dev/study-doubletap-unrevealed-{light,dark}.png` |
| 2 | PASS (see bug 4) | `testStudyEdit_editFront`: frontField "serendipity", focused, keyboard up, back visible, no ratings/reveal/counter, Done unchanged ends the edit. `010-mock-final/study-editing-front-{light,dark}.png`, `study-editing-front-forest-light.png`. In the full-suite run the keyboard went away after the edit started while the field kept focus (`010-mock/study-editing-front-light.png`); it passed twice since. Same symptom as the e2e failure: bug 4 |
| 3 | PASS | `testStudyEdit_editBackDone`: backField has the back, focused, front visible, no ratings. `study-editing-back-{light,dark}.png` |
| 4 | PASS (caret at end only) | Done key → "a happy accident" shown at once, `PATCH /cards/{id}` `{"front":"serendipity","back":"a happy accident"}`, ratings back, same card, counter "2 to review". `study-edited-light.png`. With the caret mid-text Done fails: bug 2 |
| 5 | **FAIL** | Swiping the keyboard down commits and PATCHes (passed on 61b03be, `010-mock-dev/study-edited-swipe-light.png`). **Tapping the empty card area no longer commits on daf6b4d**: bug 1 |
| 6 | PASS | `testStudyEdit_addCommitsThenOpensEditor`: PATCH sent, "New card" opens; after closing, the back shows the edit. `study-edit-add-editor-light.png` |
| 7, 8, 10, 11, 12 | n/a (unit) | Not UI-validated, per the spec. UI side of #10 checked: a foreground reload while editing calls no API and keeps the draft (`testStudyEdit_foregroundReloadSkippedWhileEditing`, `010-mock-dev/study-editing-after-foreground-light.png`) |
| 9 | PASS | Stub PATCH 500: old back comes back, `study.editError` "Couldn't save the edit" centered in the counter slot, counter hidden, still on the card. A new edit clears it, and so does rating. `study-edit-error-{light,dark}.png` |
| 13 | **FAIL** | VoiceOver announces "Actions available" on the revealed back, the first action is "Edit", and the unrevealed front has no action. But activating "Edit" does not open the field: bug 3 |
| 14 | PASS | Same font, color and centering, no border or background, pink caret (`study-editing-back-dark.png`, `study-editing-long-light.png`). Field height equals the text height (±2pt), and the front→back gap is unchanged (no layout shift). The haptic can't be observed in the simulator: left for review/device |
| 15 | PASS | 210-char back wraps (5 lines), stays centered, the field stays above the keyboard: `study-editing-long-light.png`. At AX XL the field is readable, not under the keyboard: `study-editing-xl-light.png` |
| 16 | **FAIL** (bug 4) | `testStudyEdit_appendToBack_liveAPI`: "hello" → "hello!" via Done, `GET /cards` shows it, then restored by PATCH. On daf6b4d the keyboard was gone when Done was due (Done key at y=1087, off screen), so no edit was made and the deck stayed as seeded |

Engineer's open risks: (a) tapping inside the field keeps the edit and the focus, and the caret moves where tapped:
PASS. (b) onSubmit on the vertical field on iOS 27: **does not fire**. Done with the caret at the end works only
because of the trailing-newline fallback; with the caret mid-text it inserts a newline (bug 2), so **keep the
fallback and extend it**. (c) VoiceOver: FAIL (bug 3). (d) A foreground reload doesn't clobber typing: PASS.
(e) Error line on a failed save: PASS. Tapping the non-edited side's text commits (added test): it shares the
tap-outside path, see bug 1.

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark + forest
- [x] nothing competes with the centered text; the only pink is the caret; the counter is hidden while editing. The
  keyboard's Done key is the system blue checkmark (iOS 27 system keyboard with `.submitLabel(.done)`), not app tint
- [x] circle buttons aligned, 44pt, still reachable while editing
- [x] long text wraps, no truncation
- [x] Dynamic Type XL OK
- [x] the error line is `.meta`, grey, no red or pink, centered between the corner buttons

## Bugs
1. **Tapping the empty card area does not commit the edit (regression in daf6b4d).** Stub or mock deck → reveal →
   double-tap `study.back` → type → tap inside `study.card` above the front text (e.g. (201, 186), card
   (16,122,370×348) with the keyboard up). Expected: the edit commits (PATCH, ratings back). Actual: `study.backField`
   stays, still focused, keyboard up, no PATCH, for 1s and more. The `Color.clear.onTapGesture` in `.background` of
   the ScrollView never gets the tap (the scroll view's content takes it). It passed on 61b03be. Test:
   `testStudyEdit_commitByTapOutsideAndKeyboardSwipe` (line ~150).
2. **The Done key with the caret mid-text inserts a newline and doesn't end the edit (onSubmit doesn't fire on
   iOS 27).** Reveal → double-tap the back → tap inside the field at 30% of its width (caret mid-text) → type "Z"
   → tap the keyboard's Done. Expected: the edit ends, the saved back has no newline. Actual: the field stays focused
   and grows to 2 lines (52pt): "finding somethingZ…" + newline. Spec: "return never inserts a newline". Fix: treat
   any newline the user types (not only a trailing one) as submit and drop it, keeping the existing newlines in the
   card. Test: `testStudyEdit_doneWithCaretMidText`.
3. **VoiceOver "Edit" action does not start the edit.** VoiceOver on (`XCUIDevice.voiceOverService`) → reveal →
   focus the back ("…looking for it, Actions available") → swipe down (speaks "Edit") → double-tap. Expected:
   `study.backField` opens, focused, labeled "Back". Actual: no field (no frontField either) within 3s. Tried three
   gestures. Control in the same test: a VoiceOver double-tap on "Show answer" does reveal the card, so activation
   works. Possibly the field opens and the edit ends at once (focus not taken under VoiceOver → `editEnded`). Please
   confirm on a device with VoiceOver. Test: `testStudyEdit_voiceOverEditAction`.
4. **The keyboard sometimes drops right after the edit starts. The field keeps the focus and caret but there is
   nothing to type with or press Done on.** Reveal → double-tap the back or front → (optionally type a character)
   → keyboard gone after <1s. Expected: the keyboard stays up until commit. Seen in 2 of about 6 runs on daf6b4d
   (full-suite `testStudyEdit_editFront` light, `010-mock/study-editing-front-light.png`: caret visible, no keyboard;
   e2e `testStudyEdit_appendToBack_liveAPI`: Done key off screen at y=1087), never on 61b03be. Suspect: the animated
   `proxy.scrollTo(field)` on focus, combined with `.scrollDismissesKeyboard(.interactively)`, or the new background
   tap layer. Intermittent, so please reproduce by re-running those two tests.

Tooling request: XCUITest has no API to list or perform an element's custom accessibility actions. #13 relies on
driving real VoiceOver, which is slow (~80s) and indirect. A debug-only launch argument that logs `textDoubleTapped`
/ `editEnded` actions, or a test hook, would let QA tell "action not fired" from "edit ended at once".
