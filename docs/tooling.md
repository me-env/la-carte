# Tooling inventory and proposals

Owned by `tooling-lead`. This file has one row per tool or process, then the proposals ordered by
payoff. Measurements are from 2026-11-21 (CI run 44907442393, local `qa/.results/*.xcresult`, `du`).

## Inventory

| # | Tool / process | What it does | Owner | Use | Observed pain |
|---|---|---|---|---|---|
| 1 | `scripts/api-test.sh` (7 lines) | ruff + format check + pytest | api-engineer | every API change; CI | none (CI step 7 s) |
| 2 | `scripts/api-dev.sh` (5) | uvicorn with reload | api-engineer | dev | none |
| 3 | `scripts/api-live-check.sh` (16) | compares deployed `/health` build hash with local source | api-engineer / release-engineer | after deploys | none |
| 4 | `scripts/_ios-env.sh` (5) | simulator name/OS → `-destination` | dev-velocity | sourced by all iOS scripts | one shared simulator and one default DerivedData for every agent (see 10) |
| 5 | `scripts/ios-build.sh` (8) | simulator build | ios-engineer | every iOS change | none |
| 6 | `scripts/ios-test.sh` (11) | LaCarteKit unit tests, grep-filtered output | ios-engineer | every iOS change; CI (2–2.5 min) | piped through `\|\| true` until 2026-11-21, so failures were hidden; output filtering is hand-rolled (xcbeautify does this) |
| 7 | `scripts/ios-ui-test.sh` (47) | XCUITest + xcresult export + inline Python rename of attachments | qa-validator | every feature, often several times | full suite 2.6 min (8 tests) → **41.6 min (74 tests)** in one day, ~34 s/test, serial; 1.0 GB of xcresults kept in `qa/.results` |
| 8 | `scripts/e2e.sh` (42) | two fresh APIs + seed + 6 live UI tests | qa-validator | every feature (3.4 min) | fixed ports 8765/8766: two agents can't run it at once |
| 9 | UI-test helpers: `Support.swift` (187), `StubAPIServer.swift` (251), pixel samplers in Theme/Deck/Settings/Refresh tests (~365 lines) | launch, waits, screenshots, colour asserts by sampling PNG pixels | qa-validator | all UI tests | colour checks cost a full UI test (~35 s) each; light+dark looped inside tests; dark appearance ignored on CI's iOS 26 sim (6 CI-only failures); drags can't pause mid-gesture (DEBUG launch args used instead) |
| 10 | Agent coordination | `scripts/_lock.sh` (lockf named locks, commit aa5473b); was `pgrep -x xcodebuild` polling | manager / all | every iOS run | solved for waiting: design-lead's `wait-xcodebuild.sh` request is covered by `_lock.sh` (scripts block on the lock themselves), no new script |
| 11 | `.github/workflows/ci.yml` (59) | API, docker image, iOS unit + UI + E2E | cicd-lead | every push | iOS job **~50 min** (UI step 46 min, sum of test times 2566 s); 10 tests fail only on iOS 26; E2E skipped when UI fails |
| 12 | `ci/boot-simulator.sh` (31) | pre-boot sim + `simctl ui appearance` to fix dark on CI | cicd-lead | CI | untested (not in the last pushed run); Apple forum 812656 confirms appearance is ignored under `xcodebuild` on iOS 26, no confirmed fix |
| 13 | `.github/workflows/adhoc.yml` + `ci/archive.sh`, `export-ipa.sh`, `verify-ipa.sh`, `_env.sh` (~175) | signed Ad Hoc .ipa (tags/manual) | release-engineer | releases | works; fine as is |
| 14 | `scripts/ios-adhoc.sh` (11) + `ios-install-device.sh` (38) | local Ad Hoc build; download latest CI ipa + devicectl install | release-engineer | "put it on my phone" | devicectl triggers privacy prompts: needs the user at the Mac |
| 15 | `scripts/fetch-design-refs.sh` (14) | Vyst screenshots + icon via iTunes lookup (gitignored) | design-lead / design-critic | design rounds | none |
| 16 | Brand render scripts: `docs/design/brand/render.py` (215), `explorations/render.sh` (53), 9× `explorations/round*/render.py` (1,515 lines) | hand-written seeded Python/SVG per round → rsvg-convert PNGs + a sheet | design-lead | every logo round (6 rounds, 5 passes in round 6) | each round re-implements PRNG, SVG writer, PNG export, sheet layout and its own checks; checks report per-15-px-band coverage only, which hides the joint seam (see P1) |
| 16b | Brand-render library (P5) | shared PRNG, Poisson-disc, lattice matching, SVG/PNG, sheets for new rounds | design-lead | every logo round from round 8 | done: 285 lines, selftest PASS in 3.2 s; round script ~25 lines (was 140–165) |
| 16c | Swift logo/gallery PNG renders (P6) | `ImageRenderer` in DesignSystemTests → PNGs | design-lead | every logo/design-system change | logo done (15 PNGs, 14.9 s); gallery renders blank (ScrollView), needs a `content` view exposed in `Sources` by design-lead |
| 16d | Study screen renders (P10): `ScreenColorTests/StudyRenders.swift` (109) | real `StudyView` in a UIWindow → 44 PNGs (12 states × light/dark/forest + system) | design-lead | every study-screen design change | done 2026-11-22: 30 s, byte-identical across runs; glass hidden (layer.render), judge glass on UI-test screenshots |
| 16e | `scripts/screen-sample.py` (318) (P10) | colour at a point, region uniformity, ΔE2000/WCAG diff, text contrast, min gap between colour classes, on any exported PNG | qa-validator | colour/glass/contrast ACs in qa/reports | done 2026-11-22: selftest 11/11 in 0.13 s; region on a full 3× render 0.66 s |
| 17 | Critic review sheets (scratchpad `critic/sheet*.py`, zooms) | ad hoc contact sheets, home-screen mocks with hand-drawn fake Apple icons | design-critic | every design review | replaced by `scripts/design-review.py` (P1, done): measured PASS/FAIL, sheet, home mock with real Apple icons; modes halftone (default, refuses stills of < 12 shapes), outline, flat, line (forgetting-curve geometry, 2026-11-22) |
| 18 | Marketing video pipeline (`docs/marketing/video-tools.md`) | simctl recordVideo → ffmpeg → VHS → gifski | marketing | planned | not built; ffmpeg, gifski, vhs not installed |
| 19 | `marketing/seed-demo.sh` (37) | seeds the demo deck | marketing | demo takes | none |
| 20 | Disk | — | user / release-engineer | — | **3.7 GB free**; simulators 38 GB (one shut-down iPhone 16 Pro = 19 GB), DerivedData 9.4 GB (3 folders from deleted scratchpad checkouts), `qa/.results` 1.0 GB |

## Proposals (by payoff)

### P1. `scripts/design-review.py`: measured design reviews (top priority, user-requested)

- **Owner:** design-critic (the tool and its thresholds), design-lead (render scripts, generation method).
- **Status:** **done 2026-11-21** (uncommitted, awaiting the manager). `scripts/design-review.py` (531 lines,
  2026-11-22: added overhang (ink past the solid card's edge, <= 3 px and <= 0.5%) and bbox margin imbalance (<= 10% of the tile) checks.
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
- **Update 2026-11-21 (round 7 seam; design-critic proposed, manager approved).** Round 7's ±6 px dithered
  dot → hole flip (now `round7/render_flip.py`) showed a vertical seam at x ≈ 369 and passed 18/18: the tool
  only saw ink dots, so the holes half was never analysed. Now (775 lines, ~1 s per render):
  - **Holes are marks.** Small paper components sitting in ink are detected like dots; both are stitched
    into one point set along the axis for |ψ6|, NN regularity, size and spacing.
  - **Seam checks.** `seam: polarity mix / pitch` (the zone where dots and holes mix must span ≥ 4 pitches;
    a flip in one column fails) and `seam: flip continuity step` (pitch, radius and |ψ6| of the last dots vs
    the first holes, max step ≤ 0.15).
  - **Touching exemption** `TOUCH_OK_COVERAGE = 0.65`. Below it, nothing may touch: mark to mark is measured
    on the Delaunay centre line, sub-pixel, using each mark's own extent (the apothem for hexagons), and mark
    to the rest of its colour (a dot touching the solid, a hole opening into the paper) is measured too.
    At or above it, marks may close into solid and the coverage profile alone judges that zone. Why 0.65: on
    a hex lattice, marks that keep gap ≥ 0.2·(r1+r2) top out at a hexagon of apothem ≈ 0.413·pitch, which
    is ≈ 0.68 coverage (design-lead's derivation).
  - Every line gives its location (`at x …, y … (band n)`), and the sheet circles failing marks. Several
    renders can be passed per call, and `--watch` re-runs on save.
  - `--make-synthetic` is now dots → rounded hexagons → solid, with no flip. The old AM-flip synthetic fails
    the new seam checks (polarity mix 0.0, continuity 0.161, dots touching the hole web at 0.144). The new
    one passes 12 of 12 seeds.
  - Results. round7 `flip-{light,dark}-1024.png`: PASS 18/18 → **FAIL 4/20** (polarity mix 0.0 at x 369,
    continuity 0.396, |ψ6| drawdown 0.132, NN drawdown 0.129). round7 `card-{light,dark}-1024.png` (fix b,
    hexagons): FAIL 1/18 (min gap 0.085 under the old dot-only rule) → **PASS 20/20**, but the min gap is
    0.200, right at the limit, at x 385, y 536. pass5: still FAIL 7/20, with the same values.
- **Update 2026-11-21 (round 7 defects the critic saw by eye; design-lead requested, manager approved).** Round 7
  `card-*-1024.png` passed 20/20 with hairline walls, grey mush and a bitten front; mid-animation frames were
  never checked. Now 1,013 lines, ~1.1 s per render (was 0.95 s), 24 metrics:
  - **`--frames DIR|GLOB`** (repeatable): every metric on every frame, one line per frame, then the worst frame
    per metric. The optical centre is shown but not counted on frames (a fill moves the ink centroid).
  - **Closing zone** (local coverage ≥ 0.5 up to the plateau): `closing: grey px (not AA edge) %` (luminance
    60–200 on the render normalised to paper 255 / ink 0, minus clean AA edge pixels; limit 1%) and
    `closing: hairline walls < 2 px %` (ink or paper walls a 2 px disk can't fit, runs ≥ 6 px; limit 0.5%).
  - **Front into the solid** (one-pitch box at the plateau, per row, running mean over 3 pitches):
    `front: swing px` (limit 8) and `front: raw step / 2 px` (unblurred, boxed over one lattice period; limit 0.06).
  - **Touching exemption** coverage is now measured inside the silhouette (normalised convolution, mask = convex
    hull of the ink), so closing cells at the card's edge aren't diluted by the background.
  - **`--make-synthetic` changed:** the old one closed exactly like round 7 (walls thinning to 0) and fails the
    new checks (grey 8.9%, hairlines 6.2%). Now walls stop at 2.2 px and the paper web retracts into the cell
    corners (Y holes, then shrinking holes): grey 0.47%, hairlines 0.04%, swing 3.6 px; PASS 24/24 on 12 of 12
    seeds. `scripts/brandkit.py`'s `mark()` still uses the old closing, so `brandkit.py --selftest` (e) FAILS
    until design-lead ports the new closing (owner: design-lead).
  - Results (before → after): round7 `card-{light,dark,forest}-1024.png` PASS 20/20 → **FAIL 3/24** (grey 3.6%,
    hairlines 5.7%, swing 41 px at x 527); round7 frames: worst frame FAILs |ψ6| drawdown 0.101 (frame 050), NN
    drawdown 0.100 and 4 merged blobs at x 760 (frame 025), grey/hairlines/swing (frame 075); round8
    `card-{light,dark}-1024.png` PASS 20/20 → FAIL 2/24 (hairlines 4.7%, swing 57 px); round8 frame 0.50's edge
    cells at x ≈ 715 are now exempt (a real early-closed cell at x 513 still fails). pass5 FAIL 7/20 → 8/24
    (adds raw step 0.22); round7 flip FAIL 4/20 → 6/24 (adds swing 21–40 px, raw step 0.138).

- **Update 2026-11-21 (closing holes never measured; stochastic screens; design-lead + design-critic requested,
  manager approved).** Now 1,306 lines, ~1.1–2.5 s per render, 30 metrics (lattice) / 31 (stochastic).
  - **Bug:** round 8b `card-{light,dark}-1024.png` reported **0 holes** and passed every hole/seam check. Detection
    was fine (312 holes found, verified on a 5× zoom of x 500–680: every Y hole and small hole circled; only the
    last sub-3 px specks past x ≈ 640 are below the size floor). Cause: `keep = in_rows & (mcov < 0.65)` dropped
    every mark at coverage ≥ 0.65, and a closing that keeps walls ≥ 2.2 px only breaks into holes above ≈ 0.67, so
    for this whole design family the holes were never analysed. Stitching them into the dot order bands is wrong
    too (they sit on the cell corners, a honeycomb of pitch A/√3: the lattice synthetic then fails 8 metrics).
    Fix: closing holes get their own metrics (`closing: hole size CV within band`, `… size rise` (must shrink into
    the solid), `… 1-CV(NN) floor` ≥ 0.80), and a guard `marks: empty coverage bands` FAILS when a 32 px band with
    coverage 0.05–0.95 has no detected mark (nothing measured ≠ pass; it also catches pass5's gap column).
  - **`--screen stochastic`** (default `lattice`, unchanged): order must stay even, not rise: 1-CV(NN) drawdown
    and floor ≥ 0.65, `stochastic: clumped marks %` (NN < 0.6 × the band's median NN, g(r) below the min distance,
    ≤ 2%) and `stochastic: max void / NN` (largest empty Delaunay circle ≤ 1.5 × median NN); |ψ6| drawdown INFO.
    Touching from coverage **0.35** (design-lead: d ≥ 2.4 r for the gap rule; 0.68/d² × π/5.76 ≈ 0.37; growth
    starts ≈ 0.34 with D = 2.5 R0). The closing-hole metrics are INFO (random gaps between merging disks), the
    per-row front swing is replaced by an INFO hole-area front (per 64 px strip, where paper < 2%): measured, it
    can't tell random from ragged (synthetic 16–56 px, round 9 32 px, round 7's rejected bitten front 33 px).
  - **Edge guard, both screens:** `edge: row spread at 58/29 px` (std across rows of the perceived ink, columns ≥
    0.8 coverage; ≤ 0.045 / 0.025). Lattice synthetic 0.003/0.002, round 8b 0.010/0.004, round 7 card
    0.055/0.032 (FAIL), round 9 0.061/0.021 (FAIL at 58).
  - **`--make-synthetic --screen stochastic`:** design-lead's plan via the new `brandkit.progressive_blue_noise`
    (Bridson at d/1.06 pushed apart to ≥ d: 0.68/d², the density the 0.35 derivation assumes; plain Bridson holds
    0.60/d², round 9's best-candidate set 0.49/d²; then farthest-point ranking, 0.6 s for 2,100 points). PASSES 31/31
    (default seed), 11 of 12 seeds (seed 1 fails the 58 px edge spread at 0.053). A uniform-random control FAILS
    (void 2.33, 42 merged blobs, edge 0.069).
  - Results (before → after): round 8b light/dark PASS 24/24 with 0 holes → **PASS 30/30 with 312 holes
    measured** (hole CV 0.13, rise 0, NN 0.87, edge 0.010). pass5 FAIL 8/24 → 9/30 (adds the empty band at
    x 475). round7 flip FAIL 6/24 → 7/30 (adds hole CV 0.218, light). round7 card FAIL 3/24 → 6/30 (adds hole NN
    0.66, edge 0.055/0.032). Lattice synthetic PASS 30/30 on 12 of 12 seeds. Round 9 (`--screen stochastic`):
    **FAIL 4/31** light and dark: edge spread at 58 px 0.061, merged blobs 3/2 at x 343, min gap 0.084/0.093 at
    x ≈ 372 (11 marks below), dot size CV 0.224/0.208 at x 371; frames: FAIL 6/31 (merged blobs on 5 of 5).
- **Update 2026-11-22 (round 11; design-lead reported, tooling-lead agreed).** Three fixes:
  - **Near-empty frames no longer crash.** A frame with less ink than 0.1% of the tile picked the paper as the ink
    colour (empty mark set → `ValueError`), and a ramp of 1–2 columns crashed the profile metrics (round10
    `frame-010`). Now a render with too little ink (`MIN_MEASURE_MARKS`) is `N/A`, and so is a metric with
    nothing to measure. `--frames` skips N/A frames.
  - **Sheets no longer overwrite each other.** They go to `$TMPDIR/design-review/<render's last 3 folders>/`,
    e.g. `explorations-round11-a/` and `round11-a-frames/`.
  - **Order checks are seed-stable.** A 32 px band holds 10–60 marks, so its mean |ψ6| moves by about 0.03–0.05
    with the render's seed. Across 11 seeds of round 11 a/b/c (still + 6 frames), the raw |ψ6| step was
    0.07–0.29 and the drawdown reached 0.17, so the verdict flipped with the seed. The step and drawdown (|ψ6| and
    1-CV(NN)) now count only what exceeds 2 standard errors of the band means (`ORDER_NOISE_SE`). Results:
    every round 11 seed passes them (step ≤ 0.234, drawdown ≤ 0.035). pass5 still FAILS (step 0.302), and the
    synthetic passes on 12 of 12 seeds (step ≤ 0.144). round7 flip still fails 1-CV(NN) drawdown (0.091). The
    only verdict change on the old rounds is round7 `card-frame-050` (raw |ψ6| drawdown 0.101), which now
    PASSES: that drawdown was within noise (0.031 after the correction). The remaining seed-dependence is real
    geometry: some seeds make two dots touch (`touching: min gap`), which is a defect in the render.

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

- **Owner:** cicd-lead (workflow), qa-validator (which tests form the smoke set).
- **Status:** **done** in 82574ce (PR smoke set, light only; 4 sharded UI jobs + separate E2E on main). xcbeautify (item 3) not adopted; live output is P7.

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

### P4. Colour/design checks as unit tests instead of XCUITest pixel scans (qa-validator requested; see P8)

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
  `brandkit.CLOSE_START` (0.65) is where the web starts: keep it >= design-review's `TOUCH_OK_COVERAGE`.
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

### P7. Live per-test progress, a summary line and correct exit codes (qa-validator request)

- **Owner:** dev-velocity / cicd-lead (shared scripts), qa-validator (user). **Status:** approved by the manager's brief 2026-11-21; implementer spawned.
- **Problem:** `xcodebuild … | grep` writes nothing to a file or agent log until the run ends: xcodebuild block-buffers
  stdout into a pipe, and so does grep. QA watched 30–50 min runs blind (full suite 008-r4: 75 tests, 49.3 min).
  Exit codes were reported wrong twice in one day.
- **Proposal:** `NSUnbufferedIO=YES` for xcodebuild + `grep --line-buffered` (both standard; no xcbeautify dependency),
  each finished test streamed as `[n] ✔/✘ Class.test (12.3 s)`; a final line `TESTS: 69 passed, 0 failed, 6 skipped (49.3 min)`
  from `xcresulttool get test-results summary` (UI) or the stream (unit); exit code = xcodebuild's, never masked by
  export/rename; a PATH-shim check that a failing/build-broken xcodebuild exits non-zero. **Gain:** first line within
  seconds of the first test finishing instead of at the end. **Rollback:** revert 3 scripts.

### P8. Contact sheet + one colour helper, then colour checks out of the UI suite (qa-validator request)

- **Owner:** qa-validator (UI tests, qa/), ios-engineer informed (test-only files in `LaCarteKit/Tests`). **Status:** implemented 2026-11-21,
  uncommitted. (a) `scripts/contact-sheet.py`: 170 PNGs → 107 rows, 9 pages, 5.2 s (bug: `--out` into a missing folder crashes).
  (b) 6 sampler copies → one set of helpers in `Support.swift`. (c) `AppFeatureTests/ScreenColorTests` (6 tests × 4 looks, 3.4 s);
  22 dark passes dropped from UI tests; estimated −645 s (~11 min, under the 15 min target), full-run measurement `p8-after` pending.
  Gaps: dark deck row-gap check and dark deck spinner (light + forest only). Docs still saying "light + dark" for every mock
  test: docs/testing.md, .claude/agents/qa-validator.md, docs/workflow.md, docs/ci-cd.md, docs/specs/_template.md (owner: instructions-keeper/qa-validator).
  Follow-up (ios-engineer): Settings / editor content out of the ScrollView so unit renders cover fields.
- **Evidence (008-r4):** UI suite 2,952 s; ThemeUITests 622 s; 27 light/dark loops; 5 hand-rolled samplers
  (`Pixels` in DeckUITests, `close`/`waitForColors`/`assertTextColor`/`assertStatusBar`/`assertKeyboard` in Theme,
  `assertNoBlue`/`assertInkVisible` in Refresh); 78 sampler call sites. QA opens every PNG by eye.
- **Proposal:** (a) `scripts/contact-sheet.py <run dir>` (PEP 723, pinned Pillow, `uv run`): one PNG grid, a row per
  screen, light | dark | forest side by side, names under each; `ios-ui-test.sh` runs it after export when `uv` is present.
  (b) one `ColorProbe` helper in `Support.swift` (sample, tolerance compare, luminance, "no blue", wait-until) replacing the 5 copies.
  (c) P4: token × theme × scheme colours of screens `ImageRenderer` can draw, asserted in LaCarteKit unit tests; UI
  tests keep one light + one dark/forest pass per screen for real-device chrome (status bar, keyboard, sheets).
  Target ≥ 15 min off the full suite; measured with a before/after full run.
- **Risk:** ImageRenderer can't draw List/sheets/UIKit chrome, so those checks stay in UI tests. **Rollback:** revert.

### P9. Dark appearance on the iOS 26.5 simulator, unattended (qa-validator request)

- **Owner:** cicd-lead (`ci/boot-simulator.sh`), qa-validator. **Status:** decided 2026-11-21: CI-only, documented.
- **Finding:** every way to make the *system* appearance dark on a local iOS 26 simulator needs either `simctl ui`
  (privacy prompt) or writing the device plist under `~/Library/Developer/CoreSimulator` (forbidden unattended);
  `XCUIDevice.shared.appearance` is ignored under xcodebuild on iOS 26 (Apple forum 812656). No safe local path exists.
- **Decision:** (1) dark *rendering* on iOS 26.5 locally: use the forced Dark / Forest theme (`-theme dark`), which
  works without the device appearance (triage A: forced themes rendered correctly on iOS 26). (2) "System follows device
  dark" on iOS 26: CI shards only (`ci/boot-simulator.sh`), or locally with the user at the Mac running
  `SIMULATOR=… OS=26.5 ci/boot-simulator.sh` once. (3) P8c moves most colour checks off the device appearance.

### P10. Real study-screen renders + a screenshot sampler (design-lead and design-critic requests, specs 017/019)

- **Owners:** design-lead (render method), qa-validator (sampler). **Status:** both accepted with changes, implemented 2026-11-22 (b1c518b, e1eaf7c).
- **Problem:** `ImageRenderer` draws the card's ScrollView empty, so two design rounds were judged on hand-built mocks, not
  the real view. Colour, glass and contrast acceptance criteria were judged by eye.
- **Finding:** the P8 `Screen` helper (UIWindow + `layer.render`, 3×) already drew the real StudyView. 24 renders took 48 s.
  `drawHierarchy(afterScreenUpdates:)` gave all-white PNGs (also with the window in the scene), so it isn't usable for glass.
- **Result:** `scripts/ios-test.sh --render -only-testing:ScreenColorTests/StudyRenders` gives 44 PNGs
  `screen-study-<state>-<theme>-<scheme>.png` in about 30 s. States are set as store state (`swipeEase` holds the drag).
  To add a state, add one `catalogue` line. Glass is hidden and the run says so. `uv run scripts/screen-sample.py
  at|region|diff|contrast|gap` works on any PNG; points are inferred from the width (1206/804/402), anything else fails loudly.
  Rule in docs/design-system.md: judge screens on real renders or UI-test screenshots, never mocks; judge glass on screenshots only.
- **Limits / follow-ups:** the next-card fade midpoint and 019's second drag direction aren't store state, so they aren't
  rendered. `gap` needs `--tol 0.5` next to anti-aliased greys, and can't separate the dots from the glyphs when both are ink.
  Add a back-reference comment above `expectText` once ScreenColorTests.swift is no longer dirty. Finding for design-lead:
  the answer text #9D9D9B on #F9FAF5 is 2.59:1 (below AA 4.5).
- **Rollback:** `git revert b1c518b e1eaf7c`.

## UI suite speed (audit 2026-11-21, tooling-lead)

Target: full UI suite < 10 min locally, PR smoke < 3 min. Read-only audit, no runs.

**Evidence (008-r4.xcresult, Xcode 27, 69 passed, 49.2 min serial on one simulator).** I parsed the activity timelines of all 69 tests:
- `waitForExistence`: 923 calls, 1,463 s. 896 of them took 1.0-1.5 s, and the first existence check lands at a median of
  1.037 s (p5 1.012 s) even when the element is already on screen. XCTWaiter polls once per second and that interval
  can't be configured (see the Wealthfront write-up). **About 15 min of the suite is this 1 s floor.**
- App launch/terminate: 115 launches + terminates, 586 s (about 4.5 s per launch). 46 of those launches are extra, beyond one per test.
- Taps/typing/gestures: 567 s. Element queries: 170 s. Screenshots: 2 s, so not a cost. Appearance switches: 5 s.
- Long timeouts (20 s on the closed port) are not a cost: only 27 waits went over 2 s (60 s total). Fixed `Thread.sleep`
  calls add up to about 15 s.
- Time per class: Settings+Setup 14.8 min (16 tests), Theme 10.4 (10), Deck 9.2 (22), Study 7.6 (14), Refresh 5.2 (9), DesignSystem 1.9 (4).
- No `.xctestplan`, no parallel testing, and no attachment/recording settings in `LaCarte.xcscheme`.

**Ranked changes.** Minutes are measured on 008-r4 and adjusted for P8 (branch `tooling/p8-colour-checks`, about -11 min, still unmeasured).

1. **Fast wait helper** (qa-validator, `Support.swift`): one `waitFor(_:timeout:)` that checks `exists` right away and then
   polls every 0.1 s. Replace the 61 `waitForExistence` call sites and the existence step inside `waitForLabel` with it.
   Saves about 0.75 s × 923 ≈ **11 min** (about **8-9 min** after P8). Loses no coverage. Risk: more frequent accessibility queries. Rollback: one helper.
2. **Parallel workers** (qa-validator for `ios-ui-test.sh`; dev-velocity owns the policy and the "one UI device" rule
   in dev-velocity.md): `-parallel-testing-enabled YES -parallel-testing-worker-count 3`. Xcode makes temporary clones
   of the destination. Workers take whole classes, so split `SetupUITests` out of `SettingsUITests` into its own class.
   StubAPIServer already picks a random port (20k-50k); binding port 0 would rule out collisions entirely. On 14 cores /
   48 GB: about **÷2.5** on what is left after 1+3, roughly **-12 min**. Cost: about 1 min to boot the clones, and a few GB of transient clones in
   `~/Library/Developer/XCTestDevices`, created and removed by Xcode (the user manages disk). Measure first with one parallel run on a quiet Mac.
3. **Delete logic duplicates** (qa-validator; ios-engineer confirms the unit coverage), **about -10 min**:
   - Deck: searchDebounced, swipeToDeleteCallsAPI, deleteReloadsWithQuery, deleteFailureReloads, editRowCallsPATCH,
     noMatches, addCallsPOSTAndDisablesSaveInFlight, testEditor_saveFailureKeepsText, testEditor_closeWithoutSaving,
     swipeToDeleteDark (181 s). Covered by DeckFeatureTests and CardEditorFeatureTests.
   - Study: ratingsDisabledWhileReviewInFlight, reviewFailureGoesOffline, apiUnreachable (74 s). Keep offlineThenRetry
     as the one offline screen. Merge accessibilityXL, XLLongText and XLVeryLongTextScrolls into one test (about 45 s).
   - Refresh: pullToRefreshWhenOffline, pullToRefreshWhenCaughtUp, testDeck_foregroundReload (109 s). Keep one pull test
     per screen and testStudy_foregroundReload, because that is the real scene-phase path.
   - Settings: wrongToken, unreachable, successReloadsDeckAndStudy (118 s). Keep checkingThenConnected, connectFromStudy and clearTokenFromDeck.
   - Merge Settings persistAcrossRelaunch and Theme persistsAcrossRelaunch into one relaunch test (about 60 s); it keeps the Keychain round-trip.
   - testSetup_deckStates: drop the dark pass and the offline state, which loadFailed already covers (about 60 s).
   - Coverage lost: none at the reducer level. These flows also lose their end-to-end check on real UIKit chrome; the kept tests cover each screen once.
4. **Smoke list** (qa-validator; cicd-lead wires it into PR CI): `scripts/ios-ui-test.sh <run> --smoke` expands to `-only-testing`
   for about 6 tests: frontRevealRateNext, addFromDeck, connectFromStudy, forcedSchemesAndBackToSystem (one pass),
   pullToRefreshWhileStudying, testDesignSystem_tapEachButton. Today about 6 min serial; with 1 + 2, **< 3 min**. The list lives in the script, with no test-plan file.
5. **Small fixes** (qa-validator), **about -1 min**: Theme `resetThemeOnTeardown` relaunches about 8 times (about 40 s). Drop it for tests that
   already launch with `-theme system`. Replace the fixed sleeps with waits (about 15 s).

**Projection:** 49 → about 38 (P8) → about 29 (1) → about 19 (3, 5) → **about 8 min** with 3 workers (2). Smoke about 2-3 min.
Verify each step with `TESTS: … (x min)` from a full run, in order 1 → 3 → 2.
**Status:** proposed to qa-validator and dev-velocity via the manager, 2026-11-21; no answer yet.

## Decisions log

| Date | Proposal | Owner answer | Result |
|---|---|---|---|
| 2026-11-21 | P1 design-review tool | pre-approved by the user (priority) | implementer spawn blocked by the permission classifier; brief ready, awaiting manager |
| 2026-11-21 | P1 design-review tool | manager approved for design-critic and design-lead | implemented: `scripts/design-review.py`, critic rule updated; pass5 FAILS, synthetic PASSES |
| 2026-11-21 | P3 step 1 / design-lead's `wait-xcodebuild.sh` | already solved by `scripts/_lock.sh` (aa5473b) | no new script |
| 2026-11-21 | P5 brandkit, P6 Swift renders | manager pre-approved, design-lead requested | tooling-implementers spawned |
| 2026-11-21 | stale owners (rows 4, 11, 12), P2 status | instructions-keeper via manager | fixed: dev-velocity / cicd-lead; P2 done (82574ce) |
| 2026-11-21 | P1 closing-hole bug + `--screen stochastic` (+ brandkit `progressive_blue_noise`) | design-lead + design-critic requested, manager approved | implemented: round 8b's 312 closing holes measured; stochastic mode + synthetic (11 of 12 seeds); round 9 FAILS 4/31 |
| 2026-11-21 | P7 live progress, P8 contact sheet + colour helper + P4, P9 iOS 26 dark | manager pre-approved, qa-validator requested | P7, P8 implementers spawned; P9 documented as CI-only / forced-theme locally |
| 2026-11-22 | P1 round 11 fixes: near-empty frame crash, sheet name collisions, seed-dependent order checks | design-lead reported, tooling-lead agreed | implemented: N/A instead of a crash, per-folder sheets, order step/drawdown minus 2 SE; round 11 order checks pass on 11 of 11 seeds |
| 2026-11-22 | P10 study renders + screen-sample.py | design-lead and qa-validator accepted with changes | implemented: b1c518b (44 PNGs, 30 s), e1eaf7c (selftest 11/11, 0.13 s) |
| 2026-11-22 | Batch: image-ops.py (crop, icon montage with Apple icons, video frames + transition timing via pinned PyAV 19.0.2) | design-lead/critic/QA requested, manager relayed | implemented 143ab2c (349 lines; selftest 0.24 s, synthetic 250 ms fade measured 200.0 ms for 10-90 %, expected 200, ±16 ms) |
| 2026-11-22 | Batch: screen-sample.py `bbox`, `bands`, `compare` | qa-validator requested | implemented bac74a6 (+181; selftest 25/25, 0.28 s; 0 px difference vs QA's throwaway scripts; ~0.35 s per call) |
| 2026-11-22 | Batch: design-review.py `--mode outline` (dotted-outline logo) | design-lead requested | implemented eacf3ea (+392). Old "touching" check measured no dots at all (size cap of r < 26 px). Committed dotcard renders PASS 16/16; 9 px overlap, missing and displaced dots FAIL. Thresholds await design-lead's OK |
| 2026-11-22 | Batch: design-review.py `--mode flat` (solid even-odd marks) | design-lead requested | implemented c75909b (+281). forgetcurve 01-20: 7 PASS, 13 FAIL; synthetic 20 px gap FAILS. Thresholds (35 px floor, contrast 0.25, tip loss 140 px) await design-lead's OK |
| 2026-11-22 | Batch: split not-run detection + retry (qa-validator); ios-test.sh keeps macro-expansion `note:` locations (dev-velocity) | owners requested | implemented 65d0a4e |
| 2026-11-22 | Batch: hosted-view animation recorder (test helper) | deferred by tooling-lead | SwiftUI draws through its own render tree, so a hosted view exposes no per-view `CALayer` presentation values to sample. Measure fades from recordings (`image-ops.py track`) and assert the `Animation` token in unit tests (`Animation` is Equatable). Revisit if those two are not enough |
| 2026-11-22 | Batch 2: screen-sample.py `dots` (rating dial spec 019, dotted logos, frame sequences) | design-lead requested; qa-validator (owner) and design-lead accepted with changes (merged flag, per-dot Δ / ink-track split, noise floor, --sym x/y/both, frame-to-frame count change, exact ring definition, numpy-only labelling) | implemented (+303, numpy only, no new dependency); selftest 41/41 in 0.15 s; ~1 s per call on a 1024 px render, 1.3 s on a full 3x screenshot |
| 2026-11-22 | design-review --mode line + image-ops fixes | design-lead/critic agreed metrics | implemented 1bcd871 (+~1,300 lines design-review.py, +~60 image-ops.py). Line mode: geometry from the exact SVG outline (each straight / smooth outline sample + w/2 along its inward normal = the centreline; the skeleton cuts line7's filled corners by up to 16 px on curve-93), R1-R12 metrics. curve-93: 2 FAIL of 47 (exit slope 8.6 deg < 10: chart7 cuts decay 2 at t 0.554 on the card edge, the brief's 5.6 is at the end of the drawn run 72 px outside; ink share 0.23 vs Apple 0.05-0.09); fillets all 36.0 px (8 arcs, the reported ~30 not found); tau 47.8 / 163.7 px, k 3.60 / k_visible 1.66; 3.6 s. curve-36: 8 FAIL (right gap 28 px, card wall 0.27 s, peaks 3.3 px, flat-mode 29 px fades); reset on the card edge reported as coincide. curve-39..94: 56 of 56 run, no crash, median 2.7 s, slowest 6.2 s (curve-72, under load); most frequent FAILs: card gaps 31, ink share 34, line contrast at 29 px 40, exit slope 23. Synthetic set (`--mode line --make-synthetic DIR`): clean PASSES every geometry metric, each of 8 defects fails only its own metric(s) (32 s for the 9 SVGs). Default mode now exits 2 on non-halftone stills (`--mode halftone` forces with a WARNING); flat/outline output unchanged. image-ops: `crop` takes SVG (`--svg-size`), float `--zoom` (LANCZOS), `montage` grid (`--cols`; 2 inputs + `--apple` 8 entries: 3410 x 4252 px, was 1705 x 8476). Limits: R-agreed ones as agreed; new ones (bend 15 deg/s/4, convex 1.5 deg/s/2, edge 0.15 px, fillet range 0.2-1 s, contrast 0.25 / 0.8, continuity 0.25 icon px / 0.85-1.15, occupancy +-0.05) calibrated on 93/36 + the synthetic set, awaiting design-lead's OK |
| 2026-11-22 | Icon montage one row per candidate; design-review `--out` for several renders; line-mode ink share INFO | design-lead/critic usage, tooling-lead brief | implemented (this commit; image-ops.py +53/-18, design-review.py +34/-14). `montage --apple`: one row per candidate (1024 shown at 256, 58/29 + 4x, the 6 Apple icons at 58/29 in the same row; `--cols` still wraps); curve-93-ink, curve-36-ink, curve-93-dark: 3 rows, 1651x892 px (was 9 grid entries, 5115x3196 px). Selftest: 3 inputs + --apple = 3 rows (cached icons, else stand-ins, never the network). `--out DIR/` or an existing dir: <dir>/<name>-review.png per render; `--out x.png` with several renders: x-<name>.png; every mode and `--watch` print each path (`--frames` still refuses `--out`). Line mode: `occupancy: ink share` is INFO (only Reminders and Calendar have a uniform border, range 0.05-0.09, curve-93 0.23); bbox long side stays a metric. curve-93-ink: 2 -> 1 of 47 FAIL (exit slope 8.6 deg); line synthetic 0 of 9 broken; halftone synthetic PASS |
| 2026-11-22 | Batch 3: ios-ui-test.sh `--record`; infra retry inside the scripts (`_ui-retry.sh`) | qa-validator agreed with changes (retry only if no test ran, `infra-retry: yes`); cicd-lead agreed, dropped ci/ui-test.sh's preflight branch in the same commit (qa review: else a real failure after Busy was rerun) | implemented d0fd5d4 (+150/-23). Fake xcodebuild: Busy then pass = 2 calls; Busy + failed test = 1; real `--record` 1 test 13 MB mp4 (none without); `--split 2 --record` 7 mp4s 25 MB. Test time 77 s with --record vs 49.6 s without (1 sample) |
| 2026-11-22 | Batch 3: image-ops track crash fix + events, `--match`, `--scroll-indicator`; `grid`, `strip` | tooling-lead (owner) | implemented f484ff7 (419 -> 759 lines). StopIteration on the full fix-008 recording and `--min-change 1/5` fixed (20 s, 15 events); selftest 21 checks. Scroll indicator: 10/10 true positives on 1,916 screenshots, 0 in 36,964 recording frames; not yet confirmed on a native recording that shows one |
| 2026-11-22 | Batch 3: design-review `--against` (+ `--variants`, `--json`); forgetcurve `--only` by variant number | design-lead agreed with changes | implemented fc2e72d (+381). Self PASS; 3 px shift, pink hue +15 (dE 10.7), 2 % scale each FAIL only their metric; AppIcon PNGs vs app-icon SVGs 3/3 PASS. `AGAINST_ACCENT_OUT` 0.02 awaits design-lead's OK. forgetcurve output identical for all 136 |
