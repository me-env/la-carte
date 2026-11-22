# QA: Logo 131 (card crossed by the forgetting curve) + app icon

Verdict: FAIL
Date: 2026-11-22 · Simulator: iPhone 17 Pro / iOS 27 · Commit under test: 41f0661 (branch worktree-agent-a51b387ca1abce991)
Runs: `qa/screenshots/logo-131-mock/` (scoped regression run), `qa/screenshots/logo-131-logo/` (new `LogoUITests`, final)
Commands:
- `scripts/ios-ui-test.sh --split logo-131-mock -only-testing:LogoUITests -only-testing:LaunchUITests -only-testing:LaCarteUITests -only-testing:ThemeUITests/testDesignSystem_forest`: 10 passed, 1 failed (`testLogo_launchAndLoadingMarks`, bug 1)
- `scripts/ios-ui-test.sh logo-131-logo -only-testing:LaCarteUITests/LogoUITests`: 2 passed, 1 failed (bug 1)
- `scripts/e2e.sh`: not run (no API-facing change). Full suite: not run (scope = logo only, per brief).

New tests: `ios/LaCarteUITests/LogoUITests.swift` (`testLogo_gallery` light+dark, `testLogo_galleryForest`,
`testLogo_launchAndLoadingMarks` light+dark).

## Checks
| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Gallery logo tiles light/dark/forest at 29/44/64, tokens exact | PASS | `logo-131-logo/logo-gallery-{light,dark}.png`, `logo-gallery-forest-light.png`; `screen-sample at`: light tile line #B8325A, card #1C1C1C; dark tile line #ED6E8C, card #F2F2F0; forest tile line #ED6E8C, card #EEF2EC (identical in all three runs: tiles pin their own theme) |
| 2 | Draw-in phases 40/60/80/100 % read as card first, then curve | PASS | same screenshots |
| 3 | Live marks take the running theme (launch mark: ink card + pink line) | PASS | `testLogo_gallery`/`testLogo_galleryForest` assert >200 ink and >30 accent samples in the launch mark, light/dark/forest |
| 4 | `LaCarteLaunchMark` draws in once, then stays still | PASS (stillness) / see note A | in-test: 0 changed points in the launch mark between t+4 s and t+7 s; recording strip `logo-131-logo/evidence-launch-recording-strip.png` |
| 5 | `LaCarteLoadingMark` draws and erases the curve over the card, card always visible, card never pink | **FAIL** (bug 1) | `logo-131-logo/logo-loading-pinkcard-t1119-light.png`, `evidence-loading-pinkcard-crop.png`, `evidence-loading-pinkcard-recording-strip.png` |
| 6 | Existing logo/launch-related UI tests still green (`LaunchUITests` ×4, `LaCarteUITests` gallery ×3, `ThemeUITests/testDesignSystem_forest`) | PASS | run `logo-131-mock` |
| 7 | App bundle contains the new AppIcon (light / dark / tinted) | PASS | `xcrun actool ios/LaCarte/Assets.xcassets --app-icon AppIcon` → `Assets.car`; `assetutil --info`: AppIcon Icon Image 1024² ×3: `app-icon-light.png` (no appearance), `app-icon-dark.png` (UIAppearanceDark), `app-icon-tinted.png` (ISAppearanceTintable); partial Info.plist `CFBundleIconName = AppIcon`; appiconset PNGs byte-identical to `docs/design/brand/app-icon/`; compiled 120 px icon `evidence-appicon-compiled-120.png` shows the new mark |
| 8 | App icon on the home screen (light/dark/tinted) | left for the user (device check) | needs privacy-prompting simctl/devicectl |
| 9 | Reduce Motion (static launch mark, opacity pulse) | left for the user (device check) | |
| - | Accessibility (VoiceOver labels, text size) | deferred | docs/testing.md |

Note A: `LaCarteLaunchMark` is used only in the design-system gallery (no launch or empty-state screen in the app uses
it). In the gallery its 0.9 s draw-in runs while the system launch transition is still covering the app: the first
visible recording frame (t=4.405 s) already shows the complete (faded-in) mark, so the draw-in itself can't be seen on
screen. Not a bug against this change; worth knowing before the mark is put on a real launch/empty screen (it must
appear after the app is on screen to be seen drawing).

## Visual review
- [x] Background edge to edge, light, dark and forest
- [x] Pink only on the logo's line outside the card (plus the colour swatch); no default blue tint
- [x] Mark crisp at 29 pt: card, cut-out line and pink hook all distinguishable
- [ ] Loading mark: card flashes solid pink once per loop (bug 1)

## Bugs
1. **Loading mark flashes a solid pink card once per loop.**
   Steps: launch with `LA_CARTE_SCREEN=design-system` (any theme), watch the "loading" mark at the bottom of the Logo
   section, or run `LogoUITests/testLogo_launchAndLoadingMarks`.
   Expected: the card stays ink-coloured while the curve is erased and redrawn.
   Actual: every ~1.6 s, at the turnaround where the curve restarts (card alone → first dot of the line), the whole card
   is filled with accent pink for 1-2 frames (~30-50 ms; recording t=5.302-5.333 s and 6.983 s; test frame t=1119 ms,
   1400 pink samples in the lower card).
   Root cause (reproduced off-device by compiling `LogoGeometry` + `LaCarteLogoGeometry.swift` with swiftc on macOS):
   for `progress` in (0.3, ≈0.300007], i.e. `lineTrim` in (0, ≈1e-5), `centreline.trimmedPath(from: 0, to: lineTrim)`
   is degenerate, so `line` is non-empty (`isEmpty == false`) but has a null bounding box; `line.subtracting(card)` then
   returns **the whole card**, so `lineOutside` (filled with `Theme.accent`) = the card.
   `LogoGeometry(progress: 0.3000001).lineOutside.boundingRect == (32.624, 0, 66.667, 100)` (the card rect);
   at 0.300007 it's the expected ~10×10 dot at (0.7, 20.7). The ease-in-out of `loadingPulse` lingers near the 0.3 end
   point, so the loop hits this window every cycle. The launch draw-in crosses 0.3 too and can flash the same way
   (unlikely at mid-animation speed). Suggested unit test (LaCarteLogoTests): for small `lineTrim` (e.g. progress
   0.3 + 1e-7 … 1e-5) `lineOutside` must be empty or lie outside the card.

## Tooling request
- `scripts/image-ops.py track` crashes with `StopIteration` in `transitions()` (cross(0.9)) on a region that loops
  (`track <mp4> 105,611,159,668` on `recordings/testLogo_launchAndLoadingMarks.mp4`); I fell back to `frames` + a
  hand-made strip. A `track`/`frames` option that reports per-frame colour coverage (e.g. "% of region matching
  #RRGGBB") would have found the one-frame flash directly.
- `image-ops.py montage` stacks inputs vertically only (10 crops → 1705×10588 px); a horizontal/grid strip of frame crops
  with timestamps would replace my scratch script.
