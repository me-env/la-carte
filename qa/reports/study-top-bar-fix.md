# QA note: Study top bar stays put on the last card → "All caught up"

Verdict: **PASS**
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-a49c6e2d8c3e3ec0b` (82895e0, top-aligned stack) + main merged
Runs: `qa/screenshots/final/` (`UI_WORKERS=1 scripts/ios-ui-test.sh --split 3 final`)

- `LaunchUITests` 4/4 passed, including the test that samples `study.deck` / `study.add` frames from rating the last card
  (stub `/stats` slowed 2 s) until "All caught up", then 1 s later: no move beyond 1 pt.
- Screens checked: `study-caught-up-light.png`, `study-person-*` (photo cards): buttons and counter at the same place on
  every Study state, light + dark.
- `RatingsUITests` (drag ring position) 8/8 green after the change from a safe-area inset to a top-aligned stack.
