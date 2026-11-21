# QA: 014d Study a note's direction (photo on the card face)

Verdict: **FAIL** (an unreachable photo never shows the failure placeholder)
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-a49c6e2d8c3e3ec0b` (82895e0 + main merged)
Runs: `qa/screenshots/final/`, `qa/screenshots/final-e2e/`
Commands: `UI_WORKERS=1 scripts/ios-ui-test.sh --split 3 final` (Notes Study tests ✅), `scripts/e2e.sh final-e2e` (❌ 8/9: bug 1)
Tests: `NotesUITests/testNotesStudy_photoPromptMock`, `testNotesStudy_photoAnswerAndEmptyFieldSkipped` (stub, made-up PNG),
`testNotesStudy_unreachablePhoto_liveAPI`.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | description → name + photo: prompt "runs the flower stall", answer name + photo (`study-person-description-*.png`) |
| 2 | PASS | first prompt field in `.cardFace`; answers in the back style |
| 3 | **FAIL** (live) | bug 1. Loaded case PASS: `study.photo` loads ("Photo"); fixed 240 × 300 frame, radius 20, hairline stroke (measured on screenshots: 548 px wide at 3x/1.31 scale ≈ 240 pt); live: unreachable URL stays in the loading fill (`final-e2e/study-photo-failed-light.png`) |
| 4 | PASS | photo → name + description: only the photo before reveal, no "Ada Example" in the tree (`study-person-photo-*.png`) |
| 5 | PASS | hint "Name and description?" under the photo |
| 6 | PASS | reveal shows the photo plus name and description; a person with no description shows only "Lee Park", no empty block, no URL text (`study-person-photo-revealed-*`, `study-person-empty-description-*`) |
| 7 | covered | reverse "la carte" in TestStore + 014b; not shot separately |
| 8 | PASS | after rating the person card the next card is a basic card, not a sibling (`study-after-person-*.png`) |
| 9 | unit | |
| 10 | deferred | text sizes deferred |
| 11 | see header | `testNotesStudy_unreachablePhoto_liveAPI`: prompt, reveal, rate, then `GET /cards/due` empty (sibling buried) |

## Visual review
- [x] background edge to edge, light + dark; photo centered, the front doesn't move on reveal
- [x] no accent on the card; only `study.remaining` is pink
- [x] photo URL never shown as text
- Note: the mock-notes person image is a tiny generated image, so it looks pixelated when scaled to 240 pt (mock fixture
  only; the stub's 400×500 PNG renders sharp).
- Note: `study.photo`'s accessibility frame is 300 × 302 while the drawn photo is 240 × 300 (frame-based tests can't
  measure it); not user-visible.

## Bugs
1. **Unreachable photo stays "loading" forever (014d #3).** `POST /notes` a person with `photo: http://127.0.0.1:9/nobody.png`
   (closed port: the app's own "API unreachable" tests fail on it within a second), directions `[photo]`, `[description]`;
   open Study. Expected within seconds: `person.fill` in `secondaryInk` on the hairline fill, label "Photo, not loaded".
   Actual after 15 s: plain hairline fill, no symbol, label "Photo" (`final-e2e/study-photo-failed-light.png`).
   Reveal / rate still work and the sibling is buried (`GET /cards/due` empty).
