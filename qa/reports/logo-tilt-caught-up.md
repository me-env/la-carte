# QA: Logo tilt on "All caught up" (study.logo)

Verdict: PASS
Date: 2026-11-23 · Simulator: iPhone 17 Pro / iOS 27 · Commits under test: b3d3185, 74efa31, merged with origin/main (6c65631)
on branch worktree-agent-a76b18fd1334880ae
Source of the behaviour: user requests + `docs/design-system.md` (Logo, Motion) and `docs/design/brand.md` (Motion table).
Runs: `qa/screenshots/logo-tilt-mock/` (all LogoUITests, `--record`), `qa/screenshots/logo-tilt-mock2/` (refresh test after
fixing the test, `--record`), `qa/screenshots/logo-tilt-final/` (final test file)
Commands:
- `LACARTE_AGENT=qa-logo scripts/ios-ui-test.sh --split 3 --record logo-tilt-mock -only-testing:LaCarteUITests/LogoUITests`:
  5 passed, 2 failed. Both failures were test bugs, not app bugs: the refresh test sampled during the system's app-open
  zoom (recording shows the logo finished in every frame), and the Reduce Motion test used an empty deck ("No cards yet").
- `scripts/ios-ui-test.sh --record logo-tilt-mock2 -only-testing:…/testStudy_caughtUpLogoNoReplayOnRefresh`: passed
  (foreground reload and the 30 s auto-refresh).
- `scripts/ios-ui-test.sh logo-tilt-final -only-testing:LaCarteUITests/LogoUITests` (final test file): 6 passed, 0 failed
  (3.3 min). (`--split` twice stopped at "could not list the tests in the built bundle", an infra flake under load.)
- `scripts/ios-test.sh -only-testing:ScreenColorTests/ScreenColorTests/caughtUpReduceMotion -only-testing:ScreenColorTests/StudyRenders
  -only-testing:DesignSystemTests/RenderTests` (renders on): 8 passed.
- `scripts/e2e.sh`: not run (no API change). Full suite: not run (scope = LogoUITests, per brief; CI runs the full suite).

New tests in `ios/LaCarteUITests/LogoUITests.swift`: `testStudy_caughtUpLogoDrawIn` (light + dark),
`testStudy_launchShowsFirstCardNoLogo` (light + dark), `testStudy_caughtUpLogoNoReplayOnRefresh` (stub API, light).
Stale header comment fixed (the launch mark is shown on "All caught up", never at app launch).

Dark mode: rendered correctly in these runs (dark draw-in measured with the dark accent #ED6E8C, ink card #F2F2F0 on
#1A1A1A in `study-caught-up-logo-dark.png`); the SSD-simulator dark bug did not show up.

## Acceptance criteria
| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | `study.logo` above "All caught up", plays the draw-in: line growth + card tilt that starts diagonal and flattens | PASS | `logo-tilt-mock/study-caught-up-logo-{light,dark}.png`; strips `logo-tilt-mock/strip-caught-up-drawin-{light,dark}.png` (22 frames, 40 ms apart, from the recording). Test asserts 64 pt, centred (±1 pt), maxY ≤ message minY, frames change then still after 2.5 s, settled mark has ink card + pink line. Strip: card arrives as a 3D-tilted trapezoid (diagonal), fades in, lays flat over ~1 s; the curve starts from its first peak while the card still turns. |
| 2 | Nothing at launch shows the logo or delays the first question | PASS | `logo-tilt-mock/study-launch-first-card-{light,dark}.png`. `study.front` exists 0.13 s (light) / 0.09 s (dark) after `launch()` returns; `study.logo` never seen while loading. Recording (`recordings/testStudy_launchShowsFirstCardNoLogo.mp4`): first app frame at 4.16 s (top bar only), card "serendipity" at 4.50 s, no logo in any frame. |
| 3 | Reduce Motion: static, finished mark, no tilt, no growth | PASS (unit render) | XCUITest can't turn Reduce Motion on (tried `-ReduceMotionEnabled YES` / `-UIAccessibilityReduceMotionEnabled YES`: the mark still animated, 310 changed points first frame → settled). Covered by `ScreenColorTests/caughtUpReduceMotion` (passes) and its render `logo-tilt-mock/screen-study-done-{light-light,dark-dark}.png`: finished mark, flat, centred above the message. Code path under Reduce Motion is the plain `LaCarteLogo()` (no animation modifiers). See Tooling request. |
| 4 | Auto-refresh doesn't replay the animation | PASS | `logo-tilt-mock/study-caught-up-logo-before-refresh-light.png`, `…-after-foreground-light.png`, `…-after-autorefresh-light.png`. Test waits for the app's reload request, then samples the logo for 2 s: 0 changed points vs the settled reference, after the foreground reload and after the 30 s auto-refresh. Recording strip `logo-tilt-mock/strip-foreground-no-replay.png`: the mark is finished in every frame of the app-open zoom. |

## Frame-by-frame check (the "first piece vanished and reappeared" glitch)
`image-ops.py track` on `logo-tilt-mock/recordings/testStudy_caughtUpLogoDrawIn.mp4`, logo region 150,380 → 252,480 pt,
every recorded frame (≈60 fps):
- Light, share of accent #B8325A per frame from 9.50 s: 0.0, 0.0, 0.0, 0.1, 0.6, 1.0, 1.3, 1.6, 1.6, 1.9, 2.2, 2.4, 2.4,
  2.7, 3.0, 3.3, 3.6, 3.8, 3.8 % then a plateau easing to 3.6 % as the card flattens (3D foreshortening, no step).
- Dark, accent #ED6E8C from 26.43 s: 0.1, 0.6, 1.0, 1.3, 1.6, 1.9, 2.2, 2.4, 2.4, 2.7, 3.0, 3.3, 3.6, 3.8 % then the same
  smooth plateau to 3.6 %.
- Never a drop while drawing: the first pink piece appears and stays (also visible in both strips). The in-test check
  (pink count per screenshot never below 70 % of its running max) passes light and dark.
No other glitch seen: no flash, no jump of the card, no line detached from the card during the tilt.

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark
- [x] nothing competes with the centered text, no default blue tint (logo above the title, quiet; corner buttons unchanged)
- [x] circle buttons aligned, 44 pt (unchanged, LaunchUITests-style frames identical in shots)
- [x] long text wraps, no truncation (n/a: short message)
- [ ] Dynamic Type XL: deferred (no accessibility-size checks for now)

## Notes
- Cold-launch blank period on the loaded simulator (1.5–4.1 s in the launch recording) is the system launch before the
  app's first frame, the same with or without this change; the app's own content shows the card 0.34 s after its first
  frame (mock deck load).

## Bugs
None.

## Tooling request
Reduce Motion can't be forced from XCUITest, so criterion 3 is only checked by a unit render. What would help: a
debug-only launch environment (e.g. `LA_CARTE_REDUCE_MOTION=1`) that sets `\.accessibilityReduceMotion` at the app root,
so UI tests and recordings can check every Reduce Motion variant on the device render (3D transforms included).
