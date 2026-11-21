# QA: 001 Study session (home)

Verdict: PASS (round 2)
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27
Runs: `qa/screenshots/001-mock-r2/`, `qa/screenshots/001-mock-r2-scroll/`, `qa/screenshots/001-e2e-r2/`
Commands: `scripts/ios-ui-test.sh 001-mock-r2` (✅ 15 passed, 2 `_liveAPI` skipped as designed; this run is the whole UI target, so it is also the full suite, including all 4 `testDesignSystem_*`), `scripts/ios-ui-test.sh 001-mock-r2-scroll -only-testing:…/testStudy_accessibilityXLVeryLongTextScrolls` (✅ 1 passed; test added after the full run), `scripts/e2e.sh 001-e2e-r2` (✅ 2 passed)

History: round 1 (`001-mock`, `001-e2e`) FAIL. Bug 1: long text at AX XL was clipped behind the rating row (criterion 11). Bug 2 (feel): the front jumped about 20pt on reveal. Both are fixed in round 2.

## Test changes (QA-owned, round 2)
- `testStudy_frontRevealRateNext` and `testStudy_accessibilityXL`: new `assertFrontDidNotMove`. After reveal plus the fade, `study.front` keeps its minY, midX and height within 0.5pt. Covered for a card-tap reveal and a "Show answer" reveal, in light and dark.
- `testStudy_reviewFailureGoesOffline`: now strict for the new criterion 7 rule. After a 500 on review, then a successful retry, the same card is back **revealed**: no `study.reveal`, the back is shown, and all 4 ratings are enabled. A second rating then succeeds and reaches "All caught up".
- `testStudy_accessibilityXLLongText`: rewritten for the new layout notes. The front doesn't move on reveal. `study.card` sits between the top row and the rating row. The end of `study.back` is visible, after scrolling if needed. New snapshot `study-xl-long-front`.
- New `testStudy_accessibilityXLVeryLongTextScrolls`: text that can't fit even with the cap. It checks that the card area scrolls in place and that the last line is reachable above the ratings.
- New `testStudy_accessibilityXXXLCapped`: front height at AX5 equals the height at AX XL (the cap holds), and the rating row stays usable without overlap.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `001-mock-r2/study-front-{light,dark}.png`: "serendipity" centered within 1pt, "3 to review", no back, "Show answer" |
| 2 | PASS | Card tap and "Show answer" both reveal. The back is below the front and centered, the reveal button is gone, and 4 ratings appear. **The front no longer moves**: same y in `study-front-light.png` and `study-revealed-light.png`, asserted within 0.5pt |
| 3 | PASS | Every front-state assertion checks that no `study.rate.*` exists (mock, stub, live) |
| 4 | PASS | Next card unrevealed, "2 to review", then "1 to review". Stub: one `POST /cards/<id>/review` with `"easy"`, all 4 buttons disabled in flight (`study-reviewing-light.png`, dimmed) |
| 5 | PASS | `study-caught-up-{light,dark}.png`: "All caught up" / "Next card in 9 minutes", no remaining/card/ratings. Stub 23h10m reads "Next card in 23 hours" |
| 6 | PASS | `study-empty-{light,dark}.png`, `001-e2e-r2/study-live-empty-light.png`: "Your deck is empty" |
| 7 | PASS | Offline: `study-offline-{light,dark}.png` (message + centered retry circle). Retry recovers: `study-retry-recovered-light.png`. **New rule**: after a failed review, retry brings "chat" back still revealed with ratings (`study-review-failed-light.png` → `study-review-failed-retried-light.png`), and rating it then succeeds |
| 8 | PASS (UI part) | Corner buttons 44pt, aligned, symmetric margins, on the counter line, in every state. The delegate dispatch is unit-only |
| 9 | n/a (unit) | — |
| 10 | PASS | `001-e2e-r2/study-live-front-light.png` → `study-live-light.png`: bonjour → merci → "Next card in 10 minutes". The API reports `reviewed_today == 2` |
| 11 | PASS | Fixture at AX XL: `study-xl-light.png`. The round 1 long card now fits completely, front 4 lines and back 4 lines, nothing clipped, centered, front fixed on reveal: `study-xl-long-front-light.png` → `study-xl-long-light.png`. Overflow text scrolls inside the card area, between the top row and the ratings, and the last line is reachable: `001-mock-r2-scroll/study-xl-verylong-{front,,scrolled}-light.png` |
| 12 | n/a (pytest) | Indirectly confirmed by the live caught-up and empty states |

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark (all study and design-system screenshots)
- [x] nothing competes with the centered text, no default blue tint. At default and AX XL sizes, ratings and "Show answer" are quiet ink text without fills (see note 1 for AX5)
- [x] circle buttons aligned, 44pt, with shadow in light and hairline in dark
- [x] long text wraps, no truncation. Overflow scrolls instead of clipping
- [x] Dynamic Type XL OK. The design-system gallery at XL is unchanged from round 1 (`design-system-xl-*`)

Feel compared with Vyst 01/02: the single centered word on warm paper now stays still while the answer fades in below it, which fixes the round 1 jitter. Caught-up, empty and offline remain calm, centered pairs.

## The `.accessibility2` cap
It does not make the result worse than the spec intends; it makes it better. At AX XL the card face renders at the AX2 size (about 48pt instead of about 52pt uncapped), and the front still scales more than 1.3x the default. In exchange, the round 1 failing card now fits on one screen without scrolling. Text beyond that scrolls cleanly.

## Bugs
None blocking.

## Notes (non-blocking, for the spec owner)
1. **At AX4–AX5 the chrome outgrows the capped card text.** Only card text is capped (as the spec says), so the rating row (`.body`) and the counter (`.meta`) keep growing. At AX5 "Again Hard / Good Easy" render larger than the front, and the back (`secondaryInk`) is noticeably smaller than the buttons (`study-xxxl-light.png`). This inverts "one strong thing on screen" at the very largest sizes. Option: cap the rating row and the counter at the same size, or accept it as is. It is not a spec violation.
2. **Overflow has no affordance before the first scroll.** When the revealed text overflows, the next line is cut mid-glyph at the bottom of the card area, and no scroll indicator shows until the user drags (`study-xl-verylong-light.png`). A bottom fade mask or `flashScrollIndicators` on reveal would make it obvious. It only shows up with very long cards at accessibility sizes.
3. In `study-xl-verylong-scrolled-light.png` the scroll indicator touches the ends of the longest back lines. That is the system indicator at full width, which is acceptable.
