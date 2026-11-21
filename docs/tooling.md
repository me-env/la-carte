# Tooling inventory and proposals

Owned by `tooling-lead`. This file has one row per tool or process, then the proposals ordered by
payoff. Measurements are from 2026-11-21 (CI run 44907442393, local `qa/.results/*.xcresult`, `du`).

## Inventory

| # | Tool / process | What it does | Owner | Use | Observed pain |
|---|---|---|---|---|---|
| 1 | `scripts/api-test.sh` (7 lines) | ruff + format check + pytest | api-engineer | every API change; CI | none (CI step 7 s) |
| 2 | `scripts/api-dev.sh` (5) | uvicorn with reload | api-engineer | dev | none |
| 3 | `scripts/api-live-check.sh` (16) | compares deployed `/health` build hash with local source | api-engineer / release-engineer | after deploys | none |
| 4 | `scripts/_ios-env.sh` (5) | simulator name/OS → `-destination` | release-engineer | sourced by all iOS scripts | one shared simulator and one default DerivedData for every agent (see 10) |
| 5 | `scripts/ios-build.sh` (8) | simulator build | ios-engineer | every iOS change | none |
| 6 | `scripts/ios-test.sh` (11) | LaCarteKit unit tests, grep-filtered output | ios-engineer | every iOS change; CI (2–2.5 min) | piped through `\|\| true` until 2026-11-21, so failures were hidden; output filtering is hand-rolled (xcbeautify does this) |
| 7 | `scripts/ios-ui-test.sh` (47) | XCUITest + xcresult export + inline Python rename of attachments | qa-validator | every feature, often several times | full suite 2.6 min (8 tests) → **41.6 min (74 tests)** in one day, ~34 s/test, serial; 1.0 GB of xcresults kept in `qa/.results` |
| 8 | `scripts/e2e.sh` (42) | two fresh APIs + seed + 6 live UI tests | qa-validator | every feature (3.4 min) | fixed ports 8765/8766: two agents can't run it at once |
| 9 | UI-test helpers: `Support.swift` (187), `StubAPIServer.swift` (251), pixel samplers in Theme/Deck/Settings/Refresh tests (~365 lines) | launch, waits, screenshots, colour asserts by sampling PNG pixels | qa-validator | all UI tests | colour checks cost a full UI test (~35 s) each; light+dark looped inside tests; dark appearance ignored on CI's iOS 26 sim (6 CI-only failures); drags can't pause mid-gesture (DEBUG launch args used instead) |
| 10 | Agent coordination | `scripts/_lock.sh` (lockf named locks, commit aa5473b); was `pgrep -x xcodebuild` polling | manager / all | every iOS run | solved for waiting: design-lead's `wait-xcodebuild.sh` request is covered by `_lock.sh` (scripts block on the lock themselves), no new script |
| 11 | `.github/workflows/ci.yml` (59) | API, docker image, iOS unit + UI + E2E | release-engineer | every push | iOS job **~50 min** (UI step 46 min, sum of test times 2566 s); 10 tests fail only on iOS 26; E2E skipped when UI fails |
| 12 | `ci/boot-simulator.sh` (31) | pre-boot sim + `simctl ui appearance` to fix dark on CI | release-engineer | CI | untested (not in the last pushed run); Apple forum 812656 confirms appearance is ignored under `xcodebuild` on iOS 26, no confirmed fix |
| 13 | `.github/workflows/adhoc.yml` + `ci/archive.sh`, `export-ipa.sh`, `verify-ipa.sh`, `_env.sh` (~175) | signed Ad Hoc .ipa (tags/manual) | release-engineer | releases | works; fine as is |
| 14 | `scripts/ios-adhoc.sh` (11) + `ios-install-device.sh` (38) | local Ad Hoc build; download latest CI ipa + devicectl install | release-engineer | "put it on my phone" | devicectl triggers privacy prompts: needs the user at the Mac |
| 15 | `scripts/fetch-design-refs.sh` (14) | Vyst screenshots + icon via iTunes lookup (gitignored) | design-lead / design-critic | design rounds | none |
| 16 | Brand render scripts: `docs/design/brand/render.sh` (82), `explorations/render.sh` (53), 9× `explorations/round*/render.py` (1,515 lines) | hand-written seeded Python/SVG per round → rsvg-convert PNGs + a sheet | design-lead | every logo round (6 rounds, 5 passes in round 6) | each round re-implements PRNG, SVG writer, PNG export, sheet layout and its own checks; checks report per-15-px-band coverage only, which hides the joint seam (see P1) |
| 16b | Brand-render library (P5) | shared PRNG, Poisson-disc, lattice matching, SVG/PNG, sheets for new rounds | design-lead | every logo round from round 8 | done: 285 lines, selftest PASS in 3.2 s; round script ~25 lines (was 140–165) |
| 16c | Swift logo/gallery PNG renders (P6) | `ImageRenderer` in DesignSystemTests → PNGs | design-lead | every logo/design-system change | logo done (15 PNGs, 14.9 s); gallery renders blank (ScrollView), needs a `content` view exposed in `Sources` by design-lead |
| 17 | Critic review sheets (scratchpad `critic/sheet*.py`, zooms) | ad hoc contact sheets, home-screen mocks with hand-drawn fake Apple icons | design-critic | every design review | replaced by `scripts/design-review.py` (P1, done): measured PASS/FAIL, sheet, home mock with real Apple icons |
| 18 | Marketing video pipeline (`docs/marketing/video-tools.md`) | simctl recordVideo → ffmpeg → VHS → gifski | marketing | planned | not built; ffmpeg, gifski, vhs not installed |
| 19 | `marketing/seed-demo.sh` (37) | seeds the demo deck | marketing | demo takes | none |
| 20 | Disk | — | user / release-engineer | — | **3.7 GB free**; simulators 38 GB (one shut-down iPhone 16 Pro = 19 GB), DerivedData 9.4 GB (3 folders from deleted scratchpad checkouts), `qa/.results` 1.0 GB |

## Proposals (by payoff)

### P1. `scripts/design-review.py`: measured design reviews (top priority, user-requested)

- **Owner:** design-critic (the tool and its thresholds), design-lead (render scripts, generation method).
- **Status:** **done 2026-11-21** (uncommitted, awaiting the manager). `scripts/design-review.py` (531 lines,
  PEP 723, runs with `uv run`, ~1 s per render after the first dependency install). Thresholds are the named
  constants at the top of the script (not in `design-critic.md`); the critic's rule (run it on every
  proposal, paste the report verbatim, any FAIL ⇒ ITERATE) is in `.claude/agents/design-critic.md`.
  Calibration: pass5 light and dark FAIL 7 of 18 metrics (joint step 0.195 / 8 px at 1024, 0.351 / px at
  58, |Δ²| 0.268 at 58 and 0.220 at 29, |ψ6| band step 0.346); `--make-synthetic` (density-preserving
  morph + AM-halftone inversion, see below) PASSES all 18 on 12 of 12 seeds. Deviations from this
  proposal, from calibration: the 1024 profile is blurred at the grain scale (σ = median dot NN distance)
  because raw 8 px columns alias against any lattice; the perceived blur is 0.7 icon px; the order step
  limit is 0.25, not 0.15 (per-band |ψ6| noise is ~0.05, so a smooth 6-band ramp reaches ~0.2); the
  centre check uses the optical centre (midpoint of bbox centre and ink centroid). Revisit after two rounds.

**Problem (measured on `round6/pass5/card-light-1024.png`).** The user saw a non-smooth noise→structure
transition. The critic missed it because it reviews by eye and with zoom crops, and has no numeric test for
transitions. It accepted the render script's "known limit: the jump into solid stays about ×2". The render
script checks coverage per 15 px band only, and its random zone is filled band by band, so each band
boundary is a step.
- Ink coverage per 8 px column across the ramp: it rises 0.05 → 0.47, drops to **0.23 in the 4 px gap**, then
  jumps to **1.00**. The max adjacent step is **0.77** at the joint.
- Inside the random zone, columns alternate up and down by **0.06–0.09**, for example 0.25 / 0.19 / 0.27 /
  0.21 / 0.31 / 0.22. That is band striping, not a ramp.
- I blurred the render with a Gaussian of 12 px at 1024, roughly what the eye integrates at 58 px. The slope
  is about 0.011 per column across the ramp, then **0.10–0.14 per column** over the last 5 columns: about
  10× more. Second-derivative spikes like this are what reads as a seam.
- Order changes in one step at x = 375: random dots on the left, a perfect hex lattice from there on. No
  zone mixes the two.

**Proposal.** One command the critic must run on every visual proposal and paste verbatim into its verdict.
`uv run scripts/design-review.py <render-1024.png | .svg> [--axis x] [--region x0,y0,x1,y1] [--home]` produces:
1. **Density profile** along the transition axis: per-column ink coverage (8 px columns at 1024). Fails if
   the max |step| > 0.08 or there are non-monotonic reversals larger than 0.03 inside the ramp.
2. **Perceived profile:** the same profile after a downsample to 58 and 29 px plus a Gaussian blur. Fails if
   the max |Δ²| (slope change) > 0.03 per column, i.e. a visible band or seam.
3. **Order parameter** along the axis. Dots come from the SVG circles, or from connected components of the
   PNG. Per band it computes the nearest-neighbour distance coefficient of variation and the hexatic order
   |ψ₆| (Delaunay neighbours). Each must vary monotonically with no adjacent-band step > 0.15. This catches
   "random, then suddenly a lattice".
4. **Geometry:** min gap between dots (touching/overlap), centroid vs optical centre, and a radius/stroke
   histogram.
5. **Sheet:** the render with the profile curves plotted under it on the same x axis, failing columns marked
   red, 58/29 px previews, and an optional `--home` home-screen mock at the correct icon grid. Neighbour
   icons are real Apple app icons fetched at run time through the iTunes Lookup API (`artworkUrl512`, ids
   such as Notes 1110145109, Reminders 1108187841, Calendar 1108185179). They are cached in the gitignored
   `docs/design/reference/` and never committed (Apple trademarks). Fallback: neutral superellipse stand-ins.
6. **Report:** PASS/FAIL per metric with value and threshold. The exit code is non-zero on any FAIL.

The thresholds live at the top of the script. Rule: any FAIL means ITERATE, whatever the eye
says. A claimed "known limit" is not an exemption; it is a design problem to send back.
- **Cost:** about 300–400 lines of Python, PEP 723 inline deps pinned (numpy, scipy, pillow, matplotlib),
  run with `uv`. No new system installs.
- **Risk:** thresholds that are too tight or too loose. Calibrate on pass5, which must fail, and on a smooth
  synthetic ramp, which must pass. Revisit them after two rounds.
- **Rollback:** delete the script and the critic's rule.
- **Gain:** seams like pass5's fail in seconds, before the user sees them. The ad hoc sheet scripts (~3 per
  round) go away.

**Generation proposal for design-lead (the render, not the tool).** Make the transition one continuous
field instead of three stitched zones:
- **Density-preserving morph:** generate a blue-noise point set (Bridson Poisson-disc, or a few Lloyd /
  CVT relaxation steps) and a hex lattice with the same local density, matched one-to-one (nearest
  assignment). Place each dot at `lerp(random, lattice, w(x))` with `w` a smoothstep over the whole ramp.
  Order rises continuously and density stays put. Lloyd relaxation itself is the classic noise → hexagonal
  path: the iteration count k(x) can be graded along the axis.
- **Reaching solid without touching dots:** use AM-halftone logic. Black dots grow to about 50% coverage,
  then invert to shrinking white holes in black, ending as solid. Coverage is then continuous 0 → 1 with no
  gap and no ×2 jump. Alternatively, let the solid's left edge be the halftone's own 100% end, with no gap
  column at all.
- Drive the radius from one coverage function `c(x)`, smooth with a continuous slope, not band targets.

### P2. CI iOS: 50 min → about 10 min on PRs, about 16 min full (parked behind P1)

- **Owner:** release-engineer (workflow), qa-validator (which tests form the smoke set).
- **Status:** proposed.

**Problem.** The iOS job takes about 50 min per push. The UI step is 46 min, and the 64 UI test durations
sum to 2566 s, by class: Theme 715 s, Deck 641, Study 461, Settings 335, Refresh 316, misc 97. Unit tests
take 2.5 min. E2E is skipped when UI fails, so a red run gives no E2E signal.

**Proposal.**
1. **PRs and feature pushes:** unit tests plus a light-only smoke subset (`-only-testing`, about 8 tests),
   about 8–10 min.
2. **main, nightly (`schedule:`) and `workflow_dispatch`:** one `build-for-testing` job, tar the Products
   (upload-artifact drops +x), then 4 duration-balanced shards with `test-without-building -xctestrun …
   -only-testing:`. The shards are Theme / Deck / Study / Settings+Refresh+misc, and E2E runs as its own
   job. The free plan allows at most 5 concurrent macOS jobs. Expect about 15–17 min.
3. Pipe xcodebuild through `xcbeautify --renderer github-actions` (3.2.1, preinstalled on macos-26) for
   failure annotations. It replaces the hand-rolled greps in rows 6–7.
4. For dark mode on iOS 26, run light and dark as separate shards on a simulator set with `simctl ui …
   appearance` before the tests, instead of looping appearances inside tests. Pre-booting alone has no
   confirmed fix (forum 812656). Moving colour checks to unit tests (P4) removes most of the need.

Do not rely on `-parallel-testing-enabled` on the 3-vCPU / 7 GB runner: forum threads 817089 and 733374
report stale clones and a single clone.
- **Cost:** about 60 workflow lines.
- **Risk:** shard imbalance; the Xcode and runtime must match between jobs.
- **Rollback:** revert `ci.yml`.

### P3. Local: a lock instead of `pgrep` polling, then one simulator + DerivedData per agent (parked)

- **Owner:** release-engineer (`scripts/_ios-env.sh` and the scripts), qa-validator (e2e ports).
- **Status:** step 1 done (`scripts/_lock.sh`, two-phase UI runs, free e2e ports; see `docs/dev-velocity.md`).
  Steps 2–4 parked on disk.

**Problem.** Agents poll `pgrep -x xcodebuild` and wait for up to 40 min (or 80 min in a queue). Concurrent
builds in one DerivedData fail with "database is locked" (forum 729968). The disk has 3.7 GB free.

**Proposal.**
1. **Now (about 5 lines):** re-exec each iOS script under `lockf -k -t 3600 "$TMPDIR/lacarte-sim-<sim>.lock"`.
   `/usr/bin/lockf` is on macOS, and the kernel releases the lock on exit or crash, so there is no stale
   lock. Delete the `pgrep` loops and document the lock in `docs/testing.md`.
2. **Then:** `AGENT_ID` in `_ios-env.sh` gives `simctl clone` a per-agent simulator (`-destination
   id=<UDID>`), plus `-derivedDataPath …/LaCarte-$AGENT_ID` and an `E2E_PORT` offset. About 2–4 GB per
   extra agent, so this needs P3.3 first.
3. **Disk (user's OK needed, the devices may serve other projects):** erase or delete the shut-down 19 GB
   iPhone 16 Pro and the other unused simulators, remove DerivedData folders whose workspace no longer
   exists, and prune `qa/.results` after export. About 30 GB back.
4. **Later:** `-parallel-testing-enabled YES -parallel-testing-worker-count 2` for mock UI tests only.
   StubAPIServer already uses random ports; e2e stays serial. Estimate: 40 → 20–25 min.

### P4. Colour/design checks as unit tests instead of XCUITest pixel scans (proposed, after P2)

- **Owner:** qa-validator + ios-engineer, with design-lead.
- **Status:** proposed.

**Problem.** About 365 lines of pixel samplers run inside UI tests at about 35 s each. Light and dark are
looped in-test, and dark fails on CI's iOS 26 sim.

**Proposal.** `ImageRenderer` + the existing samplers in LaCarteKit unit tests (token, card and logo colours
per theme × appearance, set with `.environment(\.colorScheme)`, no reference images). Only whole-screen
layouts get `swift-snapshot-testing` 1.19.7, pinned to one simulator and OS, with perceptualPrecision 0.98.
XCUITest keeps navigation, E2E and one appearance-switch smoke test.
- **Gain:** about 40 colour tests leave the UI suite, roughly 20 min.
- **Risk:** reference drift across iOS 26/27, and ImageRenderer can't render UIKit-backed views.

### P5. `scripts/brandkit.py`: one brand-render library for new logo rounds (design-lead request)

- **Owner:** design-lead. **Status:** **done 2026-11-21** (uncommitted). `scripts/brandkit.py` (~290 lines);
  `--selftest` ~3 s, its synthetic card PASSES design-review on 12 of 12 seeds; a minimal round script is 25 lines.
  Deviations: marks are design-review's dot → rounded-hexagon morph, not the AM inversion (a flip fails `seam:
  polarity mix`); `match` minimises squared distance (Euclidean cost let lerped dots touch on 10 of 12 seeds).
- **Evidence:** 12 render scripts, 1,788 lines. Across the 9 `render.py`: `mulberry32` defined 8×, `svg`,
  `png`, `rounded`, `smooth` 7× each, `write` 6×, `frame`/`check`/`build` 4×. Round 7 and
  `design-review.py --make-synthetic` each have their own blue-noise + `linear_sum_assignment` + `np.interp`
  copy. Bugs reported by design-lead recur per copy: unsorted `np.interp` x-points (silently wrong), lattice
  cells left unmatched and dropped.
- **Proposal:** `scripts/brandkit.py` (~250 lines, PEP 723, same pins as `design-review.py`), imported by new
  round scripts (`uv run` puts `scripts/` on the path when the round script inserts it). Uses maintained
  parts instead of hand-rolled ones: `numpy.random.default_rng` (not mulberry32), `scipy.stats.qmc.PoissonDisk`
  (Bridson, in SciPy ≥1.10), `linear_sum_assignment`, `rsvg-convert`. Functions: blue noise, hex lattice,
  one-to-one matching (asserts every cell matched), `interp` that asserts increasing x, coverage→radius /
  AM-halftone inversion, SVG writer, PNG export, contact sheet. `uv run scripts/brandkit.py --selftest`
  covers the two bug classes. Old rounds stay as history. After the in-flight `design-review.py` change
  lands, its `--make-synthetic` imports brandkit (follow-up, ~-40 lines there) so render and review share math.
- **Gain:** a new round script drops from ~150 to ~50 lines; the two bug classes fail loudly. **Risk/rollback:** delete the file.

### P6. Render the Swift logo and gallery to PNG from unit tests (design-lead request)

- **Owner:** design-lead (ios-engineer informed: test-only, no `Sources/` change). **Status:** logo done 2026-11-21:
  `scripts/ios-test.sh --render -only-testing:DesignSystemTests/RenderTests`, 15 logo PNGs at 1024 px in 14.9 s;
  full unit run unchanged (suite skipped without the env var). Gallery open: `ImageRenderer` draws its
  ScrollView empty; design-lead exposes the gallery content without the ScrollView, then a ~10-line test.
- **Evidence:** today the only way to see the Swift geometry is a UI test (~35 s each, simctl/screenshots)
  or the user's phone; the SVG and the Swift `LogoGeometry` can drift unseen.
- **Proposal:** plain SwiftUI `ImageRenderer` (Apple, no dependency) in `DesignSystemTests/RenderTests.swift`,
  enabled only when `LA_CARTE_RENDER_DIR` is set: logo at 1024 px for light/dark/forest × progress
  0, 0.25, 0.5, 0.75, 1, plus the gallery content per theme. `scripts/ios-test.sh` sets
  `TEST_RUNNER_LA_CARTE_RENDER_DIR` (xcodebuild strips the prefix) to `$LA_CARTE_SCRATCH/renders` or
  `build/renders` (gitignored) and passes extra args through (`-only-testing:DesignSystemTests/RenderTests`).
  Not swift-snapshot-testing: we want PNGs to look at and feed to `design-review.py`, not reference diffs (that
  stays P4). **Risk:** `ImageRenderer` can't draw UIKit-backed views (none in the logo; gallery checked).
  **Rollback:** delete the test file and the 2 script lines.

## Decisions log

| Date | Proposal | Owner answer | Result |
|---|---|---|---|
| 2026-11-21 | P1 design-review tool | pre-approved by the user (priority) | implementer spawn blocked by the permission classifier; brief ready, awaiting manager |
| 2026-11-21 | P1 design-review tool | manager approved for design-critic and design-lead | implemented: `scripts/design-review.py`, critic rule updated; pass5 FAILS, synthetic PASSES |
| 2026-11-21 | P3 step 1 / design-lead's `wait-xcodebuild.sh` | already solved by `scripts/_lock.sh` (aa5473b) | no new script |
| 2026-11-21 | P5 brandkit, P6 Swift renders | manager pre-approved, design-lead requested | tooling-implementers spawned |
