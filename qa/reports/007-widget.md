# QA: 007 Home Screen widget (due count + streak)

Verdict: PASS (AX-size bug fixed at d32f582; re-check below. Items left for the user still pending.)
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27 (en_US, 12-hour clock) · Code: branch at 143b9cd (review fixes)
Runs: `qa/screenshots/007-widget/` (widget gallery), `qa/screenshots/007-mock/` (regression subset), `qa/screenshots/007-e2e/`
Commands (main's test tooling, `--split`, per the manager's "feature classes + smoke only" rule):
- `scripts/ios-ui-test.sh --split 3 007-widget -only-testing:LaCarteUITests/WidgetUITests`: ✅ 4/4
- `scripts/ios-ui-test.sh --split 3 007-mock` regression subset (Settings persist + swipe-dismiss token, Theme
  persists across relaunch, `-theme forest` every screen, design-system forest, Study reveal/rate): ✅ 6/6
- `scripts/e2e.sh 007-e2e`: ✅ 6/6 live tests (incl. `testSettings_setupOnDevice_liveAPI`, relaunch with stored URL + token)
- `scripts/ios-test.sh`: ✅ 119 passed, 0 failed, 2 skipped (no DeckFeatureTests clock flake seen in this run)
- `scripts/api-test.sh`: ✅ ruff + 45 passed
- Full UI suite: **not run** (manager rule: full regression runs once after branches merge).

## What QA added
`ios/LaCarteUITests/WidgetUITests.swift` (4 tests, gallery `LA_CARTE_SCREEN=widget`):
- `testWidget_galleryAllStates`: light + dark (system theme): title, 6 tiles at 170×170, each tile's VoiceOver
  label = the expected state text, tile background = `background` token, gallery = `surface` (pixel checks);
  full + per-tile cropped screenshots.
- `testWidget_galleryForestAndForcedThemes`: `-theme forest` on a light and a dark device → forest palette;
  `-theme light` on a dark device and `-theme dark` on a light device → forced palette.
- `testWidget_storedThemeFromSettings`: Forest picked in Settings (stored in the App Group suite, no launch
  argument) → gallery relaunched in forest; teardown resets System.
- `testWidget_galleryAccessibilitySizes`: AX XL and AX XXXL, light + dark, screenshots + labels.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1–8 | PASS | pytest: `test_streak_in_utc` (param cases), `test_time_zone_with_a_positive/negative_offset`, `test_streak_across_a_dst_change`, `test_stats_rejects_an_unknown_time_zone`, `test_stats_without_tz_is_utc`, `test_mcp_review_counts_in_rest_stats`, `test_deck_stats_takes_a_time_zone` |
| 9–10 | PASS | unit: `DecodingTests`, in-memory client streak |
| 11–12 | PASS | unit: `AppGroupTests` (live client reads URL from suite, migration moves values, twice = no-op, volatile launch-arg value not treated as stored) |
| 13 | PASS (unit) / device part pending | unit `TokenMigrationTests` (`aFailedCopyKeepsTheLegacyItem`…); the upgrade-over-old-build path is part of #24 |
| 14 | PASS | `007-mock/settings-relaunched-light.png` (URL + masked token after relaunch), `study-relaunched-forest-light.png`, `study-forest-*.png`, `design-system-forest-*.png`; unit suites green |
| 15 | PASS (build + review) | app builds with the extension; not visible to XCUITest |
| 16 | PASS | `007-widget/widget-due-{light,dark,forest}.png`: "8" hero, "to review" secondaryInk, streak bottom |
| 17 | PASS | `widget-caught-up-*.png` ("Next at 6:40 PM", localized 12 h clock on this simulator), `widget-caught-up-later-*.png` ("Next on Nov 24") |
| 18 | PASS | `widget-empty-*.png` ("No cards yet" / "Ask your agent to add some") |
| 19 | PASS at default size | `widget-long-*.png`: "999" + "365-day streak" untruncated; "No streak yet" in secondaryInk; streak number pink only |
| 20 | PASS (display) | `widget-unavailable-*.png`: only "Can't reach your deck"; cache fallback = unit |
| 21 | PASS (unit + review) | refresh-date unit tests; not observable in UI |
| 22 | PASS (gallery) / Home Screen pending | `widget-gallery-forest-*.png`, `widget-gallery-forced-{light,dark}-*.png`, `widget-gallery-stored-forest-light.png` |
| 23 | PASS | `widget-gallery-{light,dark}.png`, `widget-gallery-forest-{light,dark}.png`; tiles 170×170 asserted |
| 24 | PENDING (user) | on-device install over the previous build, live count + streak, tap opens Study; also tinted/accented rendering |

## Visual review (docs/design-system.md checklist)
- [x] Background tokens: tiles `background`, gallery `surface`, light / dark / forest (pixel-asserted).
- [x] Pink only on the streak number; no blue tint.
- [x] Default text size: nothing truncates, hero/detail/streak leading-aligned, streak pinned to the bottom.
- [ ] **Dynamic Type at XL doesn't break layout: FAILS** (bug 1).
- Note (gallery only, not a bug): at AX sizes the two-line tile names make the grid rows misalign (`widget-gallery-xl-light.png`).

## Bugs
1. **The widget overflows and truncates at accessibility text sizes.** Repro: launch with
   `LA_CARTE_SCREEN=widget -UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXL`
   (`WidgetUITests/testWidget_galleryAccessibilitySizes`). Expected: every state stays readable inside the
   systemSmall tile. Actual: at AX XL every message truncates to "All ca…", "No ca…", "Next at…", "Can't reach y…",
   "12-day…" (`007-widget/widget-gallery-xl-light.png`); at AX XXXL the text spills out of the tile, above and below
   it ("12-da…" drawn under the tile, the hero above it: `widget-gallery-xxxl-dark.png`). Real Home Screen widgets
   get the user's Dynamic Type too. Suggested fix: cap the widget's text size (e.g. `.dynamicTypeSize(...DynamicTypeSize.xxLarge)`
   on `DeckWidgetView`, as system widgets do) and/or `minimumScaleFactor` on the hero; QA will re-check XL/XXXL screenshots.

## Pending (user)
- #24 device check: install the Ad Hoc build over the current one (URL + token already set), add the widget,
  confirm live due count + streak without re-entering settings, tap opens Study; check a tinted/clear Home Screen
  (accented rendering mode). Not automatable here.

## Re-check (commit d32f582, run `007-recheck`)

Fix: Dynamic Type capped at xxLarge plus `minimumScaleFactor` 0.6 on `DeckWidgetView`.
`WidgetUITests`: 4 passed, 0 failed. Screenshots: `qa/screenshots/007-recheck/`.

- Bug 1 (AX overflow): FIXED. `widget-gallery-xl-{light,dark}.png` and `widget-gallery-xxxl-{light,dark}.png`:
  all key text ("All caught up", "Next at 6:40 PM", "No cards yet", "Can't reach your deck", "12-day streak",
  "999 to review") is shown in full with no "…", and everything stays inside its tile. Text remains legible.
- Not a bug: the large grey labels under tiles are gallery captions and wrap at AX sizes, so grid rows misalign.

Still pending for the user: the checks left for the user in the earlier sections of this report (on-device
Home Screen checks).
