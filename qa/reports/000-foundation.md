# QA: 000 Foundation: walking skeleton + design system

Verdict: PASS (round 2)
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27
Runs: `qa/screenshots/000-mock-r2/`, `qa/screenshots/000-e2e-r2/`, ad-hoc: `qa/screenshots/000-adhoc-r2/`
Commands: `scripts/ios-ui-test.sh 000-mock-r2` (✅, 7 passed, `testHome_liveAPI` skipped as designed), `scripts/e2e.sh 000-e2e-r2` (✅), full suite (✅: the 000-mock-r2 run is the whole UI test target)

History:
- Round 1 (2026-11-21): FAIL. Bug 1: Dynamic Type ignored (criterion 6). Bug 2: `Theme.hairline` swatch missing from the gallery (criterion 4). Runs `000-mock/`, `000-e2e/`, `000-adhoc/`.
- Round 2 (2026-11-21): PASS. Both bugs fixed, no regressions.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `testHome_mockDeck`: `000-mock-r2/home-light.png`, `home-dark.png` ("la carte" centered within 1pt, "3 to review") |
| 2 | PASS | `testHome_liveAPI` (exactly "2 to review" for the 2 cards seeded by `scripts/e2e.sh`): `000-e2e-r2/home-live-light.png` |
| 3 | PASS | `testHome_apiUnreachable` (`LA_CARTE_API_URL=http://127.0.0.1:9`): `000-mock-r2/home-offline-light.png` |
| 4 | PASS | `testDesignSystem_gallery`: `000-mock-r2/design-system-light.png`, `-dark.png`. All 5 color tokens (background, surface, ink, secondary, hairline), the 4 type styles (cardFace "serendipity", screenTitle "Cards", body, meta), and the 4 circle buttons, in both appearances. Round-1 bug 2 is fixed |
| 5 | PASS | `testDesignSystem_tapEachButton` (all 4 buttons, "Last tapped: <symbol>") and `testDesignSystem_tapButtonEdge` (a tap 4pt inside the circle's edge still registers). Frames are at least 44x44pt. `000-mock-r2/design-system-tapped-light.png` |
| 6 | PASS | `testHome_accessibilityXL`, `testDesignSystem_accessibilityXL`: text now scales. The tests assert a height of more than 1.3x the default size, and no text overlaps or clips. `home-xl-light.png`: title and summary are visibly larger and centered. `design-system-xl-{light,dark}.png` and `-xl-scrolled-{light,dark}.png`: swatches reflow to a vertical stack, the body sample wraps to 3 lines, and the gallery scrolls with nothing clipped. Also confirmed with the simulator's system setting at accessibility XL (not just the launch argument): `000-adhoc-r2/adhoc-home-system-axl-light.png`, `adhoc-design-system-system-axl-light.png`. Round-1 bug 1 is fixed |
| 7 | PASS | Edges and corners pixel-sampled on every screenshot: `#F9FAF5` (light) and `#1A1A1A` (dark), edge to edge, including XL and scrolled. No blue tint. Circle buttons are 44pt, with a soft shadow in light and a hairline ring in dark |

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark (pixel-sampled on all 12 screenshots)
- [x] nothing competes with the centered text, no default blue tint
- [x] circle buttons aligned on one row, 44pt (shadow in light, hairline in dark), also at XL
- [x] long text wraps, no truncation (the gallery body sample wraps at XL)
- [x] Dynamic Type XL OK: home grows and stays centered, and the gallery reflows and scrolls

Feel: matches `02-editor-light.jpg` / `01-editor-dark.jpg`, with the same warm off-white and charcoal, quiet grey meta text, and white circle buttons with a soft shadow.

## Bugs
None.

## Notes
- In `design-system-xl-scrolled-*.png`, content that scrolls under the status bar is blurred by the system's
  scroll-edge effect. This is OS behavior, not a defect.
- The swatches have no accessibility identifiers (the spec doesn't require any), so the "every color token" check is a screenshot review.
- No test changes this round. The round-1 tests in `ios/LaCarteUITests/` (including the Dynamic Type scaling assertions) now pass.
