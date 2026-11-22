#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#   "numpy==2.3.4",
#   "pillow==12.0.0",
#   "scipy==1.16.3",
#   "matplotlib==3.10.7",
# ]
# ///
"""Measured design review for logo / icon renders (design-critic runs it on every proposal).

    uv run scripts/design-review.py <render-1024.png|.svg>... [--home] [--axis x|y] [--region x0,y0,x1,y1] [--out sheet.png]
    uv run scripts/design-review.py card-light-1024.png card-dark-1024.png --watch   # re-run on every save
    uv run scripts/design-review.py --make-synthetic out.png     # a smooth reference ramp that must PASS
    uv run scripts/design-review.py <render> --screen stochastic # a blue-noise (random, evenly spaced) screen
    uv run scripts/design-review.py --make-synthetic out.png --screen stochastic   # its reference, must PASS
    uv run scripts/design-review.py --frames round8/frames/  (or --frames 'round8/card-frame-*.png')   # an animation
    uv run scripts/design-review.py dotcard-light.svg dotcard-dark.svg --mode outline --dots 24 --home   # dotted outline
    uv run scripts/design-review.py forgetcurve/curve-*-ink.svg --mode flat [--home]   # solid flat marks (even-odd path)

Prints PASS/FAIL per metric (value vs limit, and WHERE: `at x 385, y 535 (band 5)` in the render's own 1024 px
coordinates; band = 32 px band counted from where the ink starts rising) and writes an annotated sheet (render,
curves under it on the same x axis, failing spots in red and failing marks circled, 58/29 px previews).
Exit code 1 on any FAIL. Several renders: each is reviewed. `--watch`: re-runs when a render's file changes
(polls mtime) and prints one PASS/FAIL line per run with the failing metrics and their spots. `--frames DIR|GLOB`
(repeatable, one per animation): every metric on every frame, one line per frame, then the worst frame per metric
(its value, frame and spot, and how many frames fail). The optical centre is shown but not counted on frames (a
fill moves the ink centroid; the still icon is reviewed on its own). A render or frame with too little ink to
measure (blank, or under MIN_MEASURE_MARKS grains: an animation's first frames) is N/A, not a crash; so is a single
metric with nothing to measure (e.g. a ramp under 3 columns). Sheets go to $TMPDIR/design-review/<the render's last
3 folders>/<name>-review.png (variants a, b, c with the same file names no longer overwrite each other).
All lengths are in px of a 1024 tile; other sizes are resampled to 1024 first. SVGs go through rsvg-convert.

Modes (`--mode`): `halftone` (default) is everything below this section: dots or holes ramping into a solid card.
`outline` is for a card outline traced by separate dots (the dotcard logo, ideation-gen/dotcard.py; the halftone
metrics, coverage ramp, front and overhang, don't apply to it). Dots come from the SVG's circles (exact) or, for a PNG,
from the peaks of the ink's distance transform (two overlapping dots stay two). The halftone mode's marks stop at 0.2%
of the tile (r ~26 px), so it never measured the dotcard's 31 px dots or its settled dot, and its touching check
passed on nothing. Outline metrics, each PASS/FAIL with value and limit (constants OUTLINE_*):
- dots: count (== `--dots N`; without it, reported only).
- path: a rounded rectangle fitted to the dot centres (straight edges through the outermost dots, the roundest
  corner radius that fits);
  dots are numbered along it clockwise from the settled dot (#1). Spacing = arc length between path neighbours: CV
  and max deviation from the mean (worst pair); max distance of a dot off the outline.
- gap: edge gap (centre distance minus both radii) between ANY two dots, min >= 8 px at 1024 (an overlap is a
  negative gap: every pair under the limit is named with its overlap in px); the CV of the neighbour gaps is INFO
  (corner chords and the settled / corner dots differ by design).
- size: diameters clustered (sorted, split at a 12% step; regular = the biggest cluster): outliers > 5% off their
  cluster's median; exactly one settled dot (>= 1.25x regular) and its ratio.
- symmetry: mirror about the vertical axis through the fitted card's centre, max position / radius error in px.
- optical centre, as in the halftone mode.
- small (58 and 29 px, the same perceived image as check 2): min peak ink over the dots (at 29 px: the outline must
  not vanish); share of neighbour pairs still separated (the ink between the centres dips below 0.85 x the fainter
  peak; INFO at 29 px, where a continuous line is acceptable); the settled dot still reads bigger (perceived ink over
  a disc of half a pitch vs the regular dots' median).
Sheet: the render with the dots numbered and ringed by size cluster, pairs under the min gap in red, spacing failures
and the worst pairs in orange; spacing and gap per pair; 58 / 29 px previews with blurred pairs marked; `--home` adds
the home-screen mock. `--watch` works; `--frames`, `--make-synthetic`, `--axis`, `--region` and `--screen` are
halftone only.
`flat` is for a solid flat mark drawn as one even-odd path (the forgetting-curve marks, ideation-gen/forgetcurve):
what is too thin to survive at icon size. Strokes and gaps are measured on the medial axis of the ink and of the
paper inside the ink's bbox (counters, cut-outs, notches; not the outer background): width = 2x the distance to the
edge, i.e. the pixels across between the two nearest edge pixels. Sharp tips (a spike, a sliver running into a
tangent, two corners touching where XOR edges cross) narrow to ~0 by construction, so they are set aside and judged
by the length they lose; runs under 10 px are corner pixels. Metrics (constants FLAT_*):
- stroke / gap: thinnest px at 1024, >= 35 (1 px at 29), with where and its size at 58 / 29 px. Only necks and
  strips count (a point no narrower than its neighbours), so the root of a tip is not taken for a stroke.
- optical centre and bbox margin imbalance, as in the halftone mode.
- small (58 and 29 px, the same perceived image as check 2): every axis point under 2 icon px is tested across: a
  stroke survives if its perceived ink exceeds both flanks (1 icon px past its edges) by >= 0.25, a gap if both
  flanks exceed it by >= 0.25 (~1 icon px at any phase). Strokes that fade and gaps that close over >= 1 icon px are
  listed with width, length and where (== 0); the longest tip lost (px at 1024, <= 140: a spike blunts, a sliver
  vanishes); INFO: the smallest neck or strip still separated at 29 px.
Sheet: the render with the medial axis (tips, corners and crossings in orange), the thinnest stroke / gap cross-
section ringed, what is lost at 29 px (red: stroke fades, blue: gap closes); 58 / 29 px previews with what is lost
at that size; `--home` adds the home-screen mock. `--watch` works; the halftone-only options are as in outline.

Screens (`--screen`, the critic picks it per proposal from the render's construction):
- `lattice` (default): the marks settle onto a hex lattice; order must RISE (checks 3), touching from coverage 0.65.
- `stochastic`: a blue-noise screen (random but evenly spaced; |psi6| stays ~0.3-0.5 by design). Order must not
  fall and must stay even instead of rising: 1 - CV(NN) drawdown and a floor, no clumped marks, no voids (3s); the
  |psi6| drawdown is INFO. Touching from coverage TOUCH_OK_COVERAGE_STOCHASTIC (0.35). The closing holes are the
  random gaps between merging disks, so their size / spacing metrics are INFO; the per-row front swing is replaced
  by an INFO hole-area front, and the edge spread at 58/29 px (6b) judges the edge. Everything else is the same.

Overhang and bbox margins (overhang counts on frames; bbox margins, like the optical centre, only on stills):
- Overhang: the card is the solid core of the ink (a 48 px opening); ink past its top, bottom or right edge (the dotted
  stream left of the card may fill the card's height) is an overhang: the farthest distance (limit 3 px) and the
  share of all ink outside (limit 0.5%). N/A without a solid card of 48 px (most older rounds, early frames).
- Bbox margin imbalance: |left - right| and |top - bottom| margins of the ink bbox in the tile, each <= 10% of the
  tile. The optical centre (3%, midpoint of bbox centre and ink centroid) is reported too: it accepts a heavy card
  balanced by a light stream, so this check only caps how far the bbox itself may sit off the tile centre (5%).
  Both must pass; neither relaxes the other.

Marks are dots (small ink components: SVG circles or PNG connected components) AND holes (small paper
components sitting in ink: the inverted image). An AM halftone flips from ink dots to paper holes at 50%
coverage; both halves are marks, stitched into one point set along the axis. Local coverage = the grain-blurred
coverage profile at the mark's x, measured inside the mark's silhouette only (normalised convolution
blur(ink*mask)/blur(mask), mask = convex hull of the ink), so cells at the card's edge aren't diluted by the
background. Where it is >= the touching exemption (TOUCH_OK_COVERAGE 0.65, stochastic 0.35) marks may touch and
close into solid: dots there are judged by coverage only (checks 1-2, 5-6), and holes there are measured on their
own (5b), not stitched into the dot order bands: a web closing puts them on the cell corners, a honeycomb of pitch
A/sqrt(3), which would read as an order drop. (Before 2026-11-21 they were dropped altogether: round 8b's ~300
closing holes were never measured and every hole/seam check passed on nothing.) The header line gives both counts.
0. Guard: every 32 px band of the ramp whose local coverage is 0.05-0.95 must hold detected marks (dots or holes);
   a band with none means nothing was measured there, which fails instead of passing.

What it measures, along the transition axis (default x; the direction of rising ink is auto-detected):
1. Coverage profile at 1024: ink per 8 px column over the middle 60% of the mark's height (avoids rounded
   corners), after a Gaussian blur at the grain scale (sigma = median mark nearest-neighbour distance), so a
   regular lattice doesn't alias against the 8 px columns. Max |step|, max drawdown (fall below the running
   max = a reversal), max |second difference| (a slope change = a visible seam).
2. The same on the 58 px and 29 px icons (area downsample + 0.7 px blur: roughly what the eye integrates).
3. Order along the axis, per 32 px band of marks (dots and holes together): hexatic order |psi6| over
   Delaunay neighbours, and regularity 1 - CV(nearest-neighbour distance). Both must rise without an
   adjacent-band step or a drop: "random, then suddenly a lattice" fails here. Both count only what exceeds
   2 standard errors of the band means (ORDER_NOISE_SE: the raw values flipped with the render's seed).
3s. Stochastic only (`--screen stochastic`), on the same bands, with l = the band's median NN distance (the density
   follows the ramp, so distances are scaled per band): 1 - CV(NN) must not fall (drawdown) and stays above
   NN_FLOOR_STOCHASTIC (Poisson-disc ~0.80-0.85, uniform random ~0.5); clumped marks (NN < 0.6 l: the pair
   correlation g(r) must be ~0 below the min distance) <= 2%; the largest empty circle (Delaunay circumradius away
   from the hull) <= 1.5 l (no voids).
4. Seam (a straight line across the axis where the pattern changes, even if coverage is smooth):
   - polarity mix: if both dots and holes exist, the zone where they mix (95th-percentile dot x minus
     5th-percentile hole x) must span >= POLARITY_MIN_MIX pitches; a dots -> holes flip in one column is a
     seam, however well its coverage matches.
   - flip continuity: the last dots and the first holes (2 pitches either side of the flip, where the hole
     fraction in a one-pitch window reaches 1/2) must match: max of |d pitch|/pitch, |d r|/max r and
     |d |psi6|| <= FLIP_STEP_MAX. The negative must continue the positive.
5. Closing zone (local coverage >= 0.5 up to the solid plateau): grey mush and hairlines.
   - grey px: % of pixels with luminance 60-200 (on the render normalised to paper 255 / ink 0) that are NOT a
     clean anti-aliased edge (a clean edge pixel has pure ink and pure paper in its 3x3); the note gives all grey.
   - hairline walls: % of pixels in ink or paper walls thinner than 2 px (4x upsample; a disk just under 2 px
     doesn't fit: grey top-hat > 0.25), counting only runs >= 6 px long (corner tips and the last specks of a
     closing hole are not walls). A web of 1 px walls between closing hexagons fails both.
5b. Closing holes (coverage >= the touching exemption), per 32 px band: size CV (one size per position), median
   radius must not rise into the solid, 1 - CV(NN) >= 0.80. INFO on a stochastic screen.
6. Front into the solid. Per row (middle 80% of the height), where coverage boxed over one pitch (inside the
   silhouette) stays at the plateau into the solid; a running mean over 3 pitches removes the lattice zigzag.
   - swing: max - min of that front (a "bitten", swinging front fails; round 7: 41 px).
   - raw step: max |step| per 2 px column of the raw (unblurred) profile, boxed over exactly one lattice period
     (autocorrelation; 2 pitches on a stochastic screen) so the lattice doesn't alias, from coverage 0.5 into the
     solid: a gap or jump at the joint.
   - stochastic: no per-row swing (50-70 px on any random screen); INFO: per 64 px strip, where the paper falls
     below 2% for good (max - min). It can't tell random from ragged (synthetic 16-56 px, round 7's bitten front 33).
6b. Edge into the solid at icon size (both screens; the guard behind the looser stochastic front): on the 58 and
   29 px perceived images, per column the std across rows of the ink, max over columns at >= 0.8 coverage. Lattice
   synthetic 0.003, round 8b 0.010, round 7's rejected bitten edge 0.055 / 0.032 (fails), round 9 0.061 (fails).
7. Geometry: merged (elongated) marks and the smallest gap / (r1+r2), both polarities: mark to mark along
   Delaunay edges (sub-pixel on the centre line; r = each mark's own extent along it, so facing hexagons
   use their apothem), and mark to the rest of its colour (a dot touching the solid or the ink between
   holes, a hole opening into the paper; pixel distance). Optical centre (midpoint of the bbox centre and
   the ink centroid) vs tile centre; mark size spread inside each band (one size per position) and size
   steps between bands.

The ramp analysed runs from the first column with ink to the first column at the solid plateau (97% of the
max), so the joint into the solid is always inside the checked range.

Synthetic reference (`--make-synthetic`, function `synthetic_ramp`), the generation idea for design-lead:
blue-noise points (Bridson Poisson-disc) matched one-to-one to a hex lattice of the same density
(linear_sum_assignment), each dot at lerp(random, lattice, w(x)) with w easing out (|psi6| only climbs
once dots are within ~0.2 pitch of their site, so a linear or smoothstep w bunches the order rise at the
end) and reaching the site by c = 0.55 (later, near-random big marks break the gap rule); one coverage
function c(x) drives one ink mark per cell: a dot, then a rounded hexagon growing into the cell, closing into
solid: walls stop at 2.2 px (c ~ 0.67), then the paper web keeps that width and retracts from the middle of each
edge into the cell corners (Y-shaped holes, then small holes shrinking to nothing), so no wall is ever thinner than
2 px. Coverage is continuous 0 -> 1 with no flip, no gap column and no jump into the solid. (The earlier
AM-halftone version, dots inverting to holes in one column at 50%, fails `seam: polarity mix`; the round-7-style
version, walls thinning to 0, fails the hairline checks.)

Stochastic reference (`--make-synthetic --screen stochastic`, function `synthetic_stochastic`), design-lead's plan:
one progressively ranked blue-noise set (brandkit.progressive_blue_noise: min distance D = 2.5 R0, every prefix
evenly spread); the density follows c(x) at radius R0 up to the full set, then the dots grow (radius calibrated so
the column coverage follows the smoothstep) and merge; radii are capped at the gap rule (D / 2.4) until coverage
0.41, then a morphological closing of radius 1.1 px fills every paper gap thinner than 2.2 px; whole dots only below
that, clipped to the card. PASSES 11 of 12 seeds (seed 1 fails the 58 px edge spread at 0.053: a random edge's
mottle can come close to round 7's bitten edge at icon size, so check a stochastic render's seed); the default passes.
"""
import argparse, json, math, os, re, subprocess, sys, tempfile, urllib.request
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
from scipy.optimize import linear_sum_assignment
from scipy.spatial import Delaunay, cKDTree

# ---- Thresholds (calibrated 2026-11-21 on round6/pass5, round7 flip-*-1024.png and round7 card-* (hairline
# walls, bitten front: the critic's eye), which must FAIL, and --make-synthetic (12 of 12 seeds), which PASSES;
# stochastic ones on --make-synthetic --screen stochastic (11 of 12 seeds), round 9 and a uniform-random control;
# revisit after two rounds). Units: coverage fraction 0..1 per column of the given size.
TILE = 1024
COL_PX = 8                      # profile column width at 1024
ROW_BAND = 0.6                  # middle fraction of the mark's height used for profiles
PLATEAU = 0.97                  # the ramp ends where coverage first reaches this fraction of its max
PROFILE_LIMITS = {              # size: (max |step|, max drawdown, max |second difference|) per column
    1024: (0.08, 0.03, 0.03),   # per 8 px column, grain-scale blur
    58:   (0.20, 0.04, 0.12),   # per icon pixel (one pixel = 17.7 px of the 1024 render)
    29:   (0.25, 0.04, 0.12),   # per icon pixel (35 px of the 1024 render)
}
PERCEIVED_BLUR = 0.7            # Gaussian sigma in icon pixels after the area downsample (eye + display)
ORDER_BAND_PX = 32              # band width for order / size statistics
ORDER_MIN_DOTS = 10             # bands with fewer marks are skipped
ORDER_MAX_STEP = 0.25           # max change of |psi6| or 1-CV(NN) between adjacent bands (band noise ~0.05)
ORDER_DRAWDOWN = 0.08           # max fall of an order measure below its running max (order must rise)
ORDER_NOISE_SE = 2.0            # both order checks count only what exceeds the bands' sampling noise: value =
                                # |difference| - 2 standard errors of that difference (SE of a band's mean |psi6| =
                                # std / sqrt(n); of its CV(NN) ~ CV sqrt((1/2 + CV^2) / n)). Why: a band holds 10-60
                                # marks, so its |psi6| moves ~0.03-0.05 with the render's seed and the raw step / drawdown
                                # flipped PASS/FAIL with the seed (round 11 a/b/c, 11 seeds: raw |psi6| step 0.07-0.29,
                                # drawdown up to 0.17). Corrected, the same renders read step <= 0.234, drawdown <= 0.035
                                # on every seed (each variant one verdict); round6/pass5 ("random, then suddenly a
                                # lattice") still fails at 0.302, round 7's flip at 1-CV(NN) drawdown 0.091, and the
                                # synthetic stays <= 0.144. A real jump is far above the noise; only noise is removed.
MIN_GAP_RATIO = 0.20            # mark gap >= 20% of the pair's summed radii (round 6 built with 25%)
MERGED_ASPECT = 1.4             # a mark blob this elongated (second moments) is two touching marks
TOUCH_OK_COVERAGE = 0.65        # touching / merging is allowed only where local coverage >= this (marks closing
                                # into solid). Why 0.65: on a hex lattice of pitch A, equal marks that keep the gap
                                # rule (gap >= 0.2*(r1+r2)) top out at a pure hexagon of apothem A/2.4 ~ 0.413*A, which
                                # covers (0.413/0.5)^2 ~ 0.68 of its cell; a closing band above ~0.68 can never pass
                                # the gap rule, so the exemption must start just below it.
TOUCH_OK_COVERAGE_STOCHASTIC = 0.35   # the same exemption under --screen stochastic (design-lead, measured on round 9):
                                # the closest blue-noise pairs sit at the min distance d; gap >= 0.2*(r1+r2) needs
                                # d >= 2.4*r; at density ~0.68/d^2 the max coverage that keeps every gap is
                                # 0.68*pi/2.4^2 ~ 0.37, and with d = 2.5*R0 the dots start growing past R0 at
                                # 0.68*pi/2.5^2 ~ 0.34, so the exemption starts just below 0.37
POLARITY_MIN_MIX = 4.0          # dots -> holes: the zone where both polarities mix must span >= 4 pitches, else
                                # the flip is a straight front (a seam), whatever the coverage does
FLIP_STEP_MAX = 0.15            # last dots vs first holes (2 pitches each side of the flip): max of |d pitch|/pitch,
                                # |d radius|/max radius and |d |psi6||; the negative must continue the positive
CENTROID_TOL = 0.03             # optical centre (midpoint of bbox centre and ink centroid) within 3% of the
                                # tile (31 px) of the tile centre, per axis
OVERHANG_PX = 3                 # ink outside the card's silhouette edge: farthest ink <= 3 px (anti-aliasing) beyond it,
OVERHANG_SHARE = 0.005          # and <= 0.5% of all ink outside. A loose dot poking past the card's edge reads as a
                                # defect at 58/29 px; the card is the solid core (CARD_CORE_PX opening), the dotted
                                # stream to its left is allowed inside the card's height only
CARD_CORE_PX = 48               # the card = ink surviving a 48 px square opening (dots/ramp are smaller than that)
BBOX_IMBALANCE = 0.10           # |left - right| (and |top - bottom|) margin of the ink bbox <= 10% of the tile, i.e.
                                # the bbox centre within 5% of the tile centre; the optical centre (3%) may let the
                                # centroid offset a lopsided bbox, this caps how far
SIZE_CV_MAX = 0.20              # mark radius CV inside one band (one size per position)
SIZE_STEP_MAX = 0.20            # change of median mark radius between adjacent bands, as a fraction of the max
# Stochastic screen (--screen stochastic: blue noise, |psi6| low by design). Order must not fall, and the marks must
# stay evenly spaced, neither clumped nor with holes in the point set. Per 32 px band, scaled by the band's median NN
# distance l (the density follows the ramp, so a global g(r) would mix scales):
NN_FLOOR_STOCHASTIC = 0.65      # min 1 - CV(NN) per band (Bridson Poisson-disc points ~0.91, uniform random points
                                # ~0.48; on rendered marks the stochastic synthetic's bands read 0.73-0.87, and a
                                # uniform-random version 0.70, because overlapping random dots merge into one mark:
                                # it fails on voids, merged blobs and gaps instead)
CLUMP_RATIO = 0.6               # a mark whose NN distance < 0.6 l is clumped: the pair correlation g(r) must be ~0
                                # below the min distance (blue noise ~0%, uniform random ~20% of marks)
CLUMP_MAX = 2.0                 # % of marks clumped (synthetic 0%; touching random dots merge into one mark, so a
                                # uniform-random render shows 1.4% here and fails `touching: merged blobs` instead)
VOID_MAX = 1.5                  # largest empty circle (Delaunay circumradius inside the analysed marks) / l
                                # (synthetic 1.19-1.41 over 12 seeds, round 9 1.46, uniform random 2.33)
# Closing marks (local coverage >= the touching exemption): holes are measured on their own (a web closing puts them
# on the cell corners, a honeycomb of pitch A/sqrt(3), so they are not stitched into the dot order bands). Per band:
CLOSING_HOLE_RISE_MAX = 0.10    # holes shrink into the solid: max rise of the band's median hole radius, / max radius
CLOSING_HOLE_NN_FLOOR = 0.80    # min 1 - CV(NN) of the holes (lattice; on a stochastic screen the three closing-hole
                                # metrics are INFO: holes between merging random disks vary by design)
MARKS_MIN_COVERAGE = (0.05, 0.95)   # a 32 px band whose local coverage is in this range must contain detected marks:
                                    # nothing detected there means nothing measured, which is not a pass
# Closing zone (local coverage >= CLOSING_COVERAGE, up to the solid plateau): hairlines and grey mush.
CLOSING_COVERAGE = 0.5
GREY_INK = (0.216, 0.765)       # "grey" = luminance 60..200 of 8 bit on the render normalised to paper 255 / ink 0
                                # (so light, dark and coloured variants measure the same): ink fraction in this range
GREY_EXCESS_MAX = 1.0           # % of closing-zone px that are grey AND not a clean anti-aliased edge (a clean edge
                                # pixel has a pure ink and a pure paper pixel, <= 0.1 / >= 0.9, in its 3x3)
THIN_WALL_PX = 2.0              # ink or paper walls thinner than this (at the 50% level) are hairlines
HAIRLINE_MIN_LEN = 6            # px: a thin run at least this long is a wall; shorter ones are tips / last specks
THIN_WALL_MAX = 0.5             # % of closing-zone px inside a hairline wall (the last sub-2 px specks of a closing
                                # hole are allowed; a web of 1 px walls is not)
# Front into the solid: per row, where coverage (ink boxed over one pitch, so a closing hole doesn't break it) stays
# >= PLATEAU into the solid, over the middle FRONT_ROW_BAND of the mark's height, then a running mean over 3
# pitches along the front (averages out the lattice's own zigzag, ~0.6 pitch).
FRONT_ROW_BAND = 0.8
FRONT_SWING_MAX = 8.0           # px: max - min of the smoothed front (synthetic ~1, round 7's bitten front ~41)
FRONT_RAW_STEP_MAX = 0.06       # max |step| per 2 px column of the raw profile (no blur; only a box of one lattice
                                # period, which removes the lattice's own aliasing) from coverage 0.5 into the solid

# Stochastic front (--screen stochastic): the per-row swing is 50-70 px on any random screen (round 9, the synthetic),
# so the front is taken per strip: where the paper (hole) area falls below FRONT_HOLE_FRAC for good.
FRONT_HOLE_FRAC = 0.02
FRONT_STRIP_PX = 64
FRONT_SPREAD_MAX = 24.0         # px: max - min of the strip fronts (8 px columns). INFO only: on a random screen the
                                # strip front is ill-conditioned (coverage is flat near the solid) and spreads 16-56 px
                                # on the passing synthetic, 31 px on round 9, vs 33 px on round 7's rejected bitten
                                # front: it can't tell random from ragged. The edge spread (below) can, in coverage.
# Edge guard (both screens): a ragged edge into the solid reads at icon size even when a front metric passes.
# Perceived image (58 / 29 px, as in check 2); columns at >= EDGE_MIN_COVERAGE; std across rows. Calibration:
# lattice synthetic 0.003 / 0.002, round 8b 0.010 / 0.004; round 7's rejected bitten front 0.055 / 0.032.
EDGE_MIN_COVERAGE = 0.8
EDGE_SPREAD_MAX = {58: 0.045, 29: 0.025}
# Nothing to measure: a render (e.g. the first frame of a "grain streams in" animation) whose colours are all within
# INK_MIN_CONTRAST of the paper, or with fewer than MIN_MEASURE_MARKS marks, gets every metric reported N/A (it
# neither passes nor fails anything): order, spacing and profiles need a few marks to mean anything.
INK_MIN_CONTRAST = 0.1          # RGB distance 0..sqrt(3)
MIN_MEASURE_MARKS = 8

# ---- Outline mode (`--mode outline`): a card outline traced by separate dots (the dotcard logo, round 4, 2026-11-22).
# Calibrated on the committed dotcard-light.svg / dotcard-round-light.svg (the intended design: PASS) and scratch
# variants that must FAIL (two dots overlapping by ~9 px, a dot missing, a dot moved 1/4 pitch along the path).
OUTLINE_MAX_R = 0.1             # SVG circles under 0.1 x the tile in radius are dots (bigger ones are backgrounds)
OUTLINE_SPACING_CV = 0.03       # CV of the arc length between path neighbours along the fitted card outline
                                # (committed 0.003 / 0.000; a dot moved 1/4 pitch 0.072, a missing dot 0.196)
OUTLINE_SPACING_DEV = 0.10      # max |spacing - mean| / mean along the path (a dot moved 1/4 pitch: 0.25; a missing dot:
                                # one pair at ~2 pitches)
OUTLINE_OFFPATH_PX = 3.0        # max distance of a dot centre from the fitted rounded rectangle, px at 1024
OUTLINE_MIN_GAP_PX = 8.0        # edge gap (centre distance minus both radii) between ANY two dots, px at 1024; <= 0 is
                                # an overlap. 8 px is 0.45 px at 58 px: below it the pair reads as one blob. The gaps'
                                # CV is reported, not counted: equal arc spacing makes chords across a corner shorter
                                # (1-pitch arc: 0.90 p) and the settled / corner dots' gaps differ by design
OUTLINE_CLUSTER_SPLIT = 1.12    # sorted diameters split into size clusters where one is > 12% above the previous
OUTLINE_SIZE_TOL = 0.05         # a dot more than 5% off its cluster's median diameter is an outlier
OUTLINE_SETTLED_MIN = 1.25      # the settled dot = a dot >= 1.25 x the regular (most common) diameter; exactly one
OUTLINE_SYMMETRY_PX = 2.0       # mirror about the vertical axis through the fitted card's centre: max position or radius
                                # error of a dot vs its mirror partner, px at 1024 (committed 0.0)
OUTLINE_PEAK_MIN = {58: 0.55, 29: 0.18}   # min over dots of the perceived peak ink (0 paper .. 1 ink) at icon size;
                                # at 29 px this is the "outline vanishes" check. Committed equal dots 0.83 / 0.38, round
                                # corners (0.75x) 0.66 / 0.22; 0.6x corner dots (rejected: "fade out at 58 px") 0.50 / 0.14
OUTLINE_VALLEY = 0.85           # a neighbour pair stays separated at icon size if the perceived ink between the two
                                # centres dips below 0.85 x the fainter dot's peak (else they blur into a line)
OUTLINE_SEPARATED_MIN = {58: 0.90, 29: None}   # min share of separated neighbour pairs (committed 1.00 at 58 px; 0.83 /
                                # 0.75 at 29 px, where a continuous line is acceptable: reported, not counted)
OUTLINE_SETTLED_SMALL = 1.25    # at 58 and 29 px: the settled dot's perceived ink (mean over a disc of half a pitch)
                                # / the regular dots' median; it must still read bigger (committed 1.89 / 1.78 at 1.5x)
OUTLINE_EXACT = ("dots: count", "size: settled dots")   # metrics compared with ==

# ---- Flat mode (`--mode flat`): a solid flat mark drawn as one even-odd path (the forgetting-curve marks,
# ideation-gen/forgetcurve, 2026-11-22). Calibrated on curve-01..20-ink.svg and straight strokes / slots of known width
# at every sub-pixel phase (contrast below); proposed to design-lead, to confirm after a round.
FLAT_OPPOSITE_COS = -0.5        # a medial-axis point: two neighbouring pixels whose nearest boundary points lie >= 120
                                # degrees apart seen from them (cos <= -0.5): necks, strips and wedges under 60 degrees;
                                # not 90-degree corners (cos 0) nor anti-aliasing steps on a straight edge (same side)
FLAT_MIN_PX = 35.0              # thinnest stroke and thinnest gap at 1024, sharp tips excluded: 1 px at 29 (35.3 px)
FLAT_TIP_PX = 12.0              # a sharp tip (a spike, or two corners meeting where XOR edges cross): a thin run of the
                                # axis that narrows to <= 12 px (the last pixels before a sharp point drop off the axis)
                                # and opens like a wedge from there (is_tip). Its width always reaches ~0, so it is
                                # judged by the length it loses at icon size, not by its width; a hairline seam (near-
                                # coincident edges) stays even and counts as a stroke or gap
FLAT_TIP_OPEN = 0.1             # ... or opening both ways at >= 0.1 px of width per px of length (a ~6-degree wedge)
FLAT_CORNER_PX = 10.0           # a thin run shorter than 10 px (0.3 px at 29) is a point, not a feature: the last pixels
                                # of a corner, or where two XOR edges cross (two corners touching); set aside with the tips
FLAT_TEST_MAX = 2.0             # only axis points under 2 icon px wide are tested at 58 / 29 px (wider ones keep
                                # contrast >= 0.6 at any phase)
FLAT_CONTRAST = 0.25            # a stroke survives at icon size if its perceived ink exceeds both flanks (1 icon px past
                                # its edges, across it) by >= 0.25; a gap if both flanks exceed it by >= 0.25. Straight
                                # stroke or slot, worst / mean of 8 phases at 29 px: 20 px 0.12 / 0.17, 30 px 0.22 / 0.28,
                                # 35 px 0.27 / 0.33, 50 px 0.43 / 0.47 (gaps the same); so 0.25 = ~1 icon px at any phase
FLAT_VANISH_LEN = 1.0           # a stroke that fades / a gap that closes counts once its failing run spans >= 1 icon px
                                # (35 px at 29): a shorter one is not a visible feature at that size (e.g. the root of a
                                # spike next to its tip, 31 px on curve-07)
FLAT_TIP_LOSS = {58: 140.0, 29: 140.0}   # max length of a sharp tip lost at icon size, px at 1024 (4 icon px at 29):
                                # the tooth spikes of curve-01..20 lose 40-130 px at 29 (a point blunts), the XOR
                                # slivers (a disc's edge running tangent into the curve) 160-250 px (a sliver vanishes)
FLAT_EXACT = ("small: faded strokes", "small: closed gaps")   # metrics compared with ==

ICON_IDS = [1110145109, 1108187841, 1108185179, 1069512882, 1584215688, 915056765]   # Notes, Reminders,
# Calendar, Stocks, Clock, Maps: Apple's own apps via the public iTunes lookup API (no personal data).
ICON_CACHE = Path(__file__).resolve().parent.parent / "docs/design/reference/home-icons"   # gitignored


# ---------------------------------------------------------------- loading
def load(path, axis):
    path = Path(path)
    circles = None
    if path.suffix.lower() == ".svg":
        circles = svg_circles(path.read_text())
        png = Path(tempfile.mkdtemp()) / "render.png"
        subprocess.run(["rsvg-convert", "-w", str(TILE), "-h", str(TILE), str(path), "-o", str(png)], check=True)
        path = png
    img = Image.open(path).convert("RGB")
    if img.size != (TILE, TILE):
        img = img.resize((TILE, TILE), Image.LANCZOS)
    rgb = np.asarray(img, dtype=float) / 255
    if axis == "y":
        rgb = rgb.transpose(1, 0, 2)
        if circles is not None:
            circles = circles[:, [1, 0, 2]]
    return img, rgb, circles


def svg_circles(text):
    """Circles (cx, cy, r) in 1024 px, or None if the SVG uses transforms (then PNG blobs are used)."""
    if "transform" in text:
        return None
    vb = re.search(r'viewBox="([\d.\s-]+)"', text)
    scale = TILE / float(vb.group(1).split()[2]) if vb else 1.0
    out = []
    for tag in re.findall(r"<circle\b[^>]*>", text):
        a = dict(re.findall(r'(\w+)="([^"]*)"', tag))
        out.append([float(a.get("cx", 0)) * scale, float(a.get("cy", 0)) * scale, float(a.get("r", 0)) * scale])
    return np.array(out) if out else None


def ink_map(rgb):
    """0 = background colour (from the corners), 1 = ink colour (the colour furthest from it)."""
    c = 16
    bg = np.median(np.concatenate([rgb[:c, :c], rgb[:c, -c:], rgb[-c:, :c], rgb[-c:, -c:]]).reshape(-1, 3), axis=0)
    d = np.linalg.norm(rgb - bg, axis=2)
    if d.max() < INK_MIN_CONTRAST:                     # blank (e.g. the first frame of an animation): no ink
        return np.zeros(d.shape), bg, bg
    # the top 0.1% of pixels, but never the paper: with less ink than that (a near-empty frame) the percentile
    # falls on the background and the ink colour would be the paper's
    ink = np.median(rgb[d >= max(np.percentile(d, 99.9), d.max() / 2)], axis=0)
    v = ink - bg
    return np.clip(((rgb - bg) @ v) / (v @ v), 0, 1), bg, ink


# ---------------------------------------------------------------- dots
def detect_marks(ink, circles):
    """Marks of both polarities. Returns (marks[n, 5] = x, y, r, polarity (+1 dot, -1 hole), elongated 0/1;
    labels {+1: ink labels, -1: paper labels}; mark label ids {+1: ids, -1: ids} in the same order as marks).
    Big shapes (the solid, the paper ground) are not marks."""
    out, labels, ids = [], {}, {}
    for pol, mask in ((1, ink > 0.5), (-1, ink <= 0.5)):
        lab, n = ndimage.label(mask)
        idx = np.arange(1, n + 1)
        areas = ndimage.sum(np.ones_like(ink), lab, idx)
        small = (areas >= 3) & (areas < 0.002 * TILE * TILE)
        if pol == -1:                                  # a hole sits in ink: the ring 2 px around it is mostly ink
            for i, sl in enumerate(ndimage.find_objects(lab)):
                if not small[i]:
                    continue
                sl = tuple(slice(max(a.start - 3, 0), a.stop + 3) for a in sl)
                own = lab[sl] == i + 1
                ring = ndimage.binary_dilation(own, iterations=2) & ~ndimage.binary_dilation(own, iterations=1)
                small[i] = ring.any() and ink[sl][ring].mean() > 0.5
        elong = np.zeros(n, bool)
        for i, sl in enumerate(ndimage.find_objects(lab)):
            if small[i] and areas[i] > 12:
                pts = np.argwhere(lab[sl] == i + 1).astype(float)
                ev = np.linalg.eigvalsh(np.cov(pts.T))
                elong[i] = math.sqrt(ev[1] / max(ev[0], 1e-9)) > MERGED_ASPECT
        keep = idx[small]
        labels[pol], ids[pol] = lab, keep
        if not len(keep):
            continue
        cy, cx = np.array(ndimage.center_of_mass(mask, lab, keep)).T.reshape(2, -1)
        out.append(np.column_stack([cx, cy, np.sqrt(areas[small] / math.pi), np.full(len(keep), pol), elong[small]]))
    marks = np.concatenate(out) if out else np.zeros((0, 5))
    if circles is not None:                            # exact dot geometry from the SVG (PNG elongation kept)
        dots = circles[circles[:, 2] < 0.05 * TILE]
        tree = cKDTree(dots[:, :2])
        d = marks[:, 3] > 0
        if d.any():
            j = tree.query(marks[d, :2])[1]
            marks[d, :3] = dots[j]
    return marks, labels, ids


def mark_gaps(ink, marks, labels, ids, cov, touch):
    """Smallest gap / (r1 + r2) per mark (np.inf if none measured), exempt where local coverage cov(x) >=
    touch (TOUCH_OK_COVERAGE, or TOUCH_OK_COVERAGE_STOCHASTIC). Mark to mark: along Delaunay edges between marks of the same polarity, sub-pixel on the
    centre line, r1 and r2 = each mark's extent along that line. Mark to the rest of its colour (the solid, the ink web between holes, the paper ground):
    pixel distance transform, against a partner of the same radius."""
    ratio = np.full(len(marks), np.inf)
    for pol in (1, -1):
        sel = np.nonzero(marks[:, 3] == pol)[0]
        if not len(sel):
            continue
        m = marks[sel]
        e = np.zeros((0, 2), int)
        if len(m) >= 4:
            tri = delaunay(m[:, :2])
            e = np.unique(np.sort(np.concatenate([tri.simplices[:, [0, 1]], tri.simplices[:, [1, 2]],
                                                  tri.simplices[:, [0, 2]]]), axis=1), axis=0)
            a, b = m[e[:, 0], :2], m[e[:, 1], :2]
            rs = m[e[:, 0], 2] + m[e[:, 1], 2]
            L = np.hypot(*(b - a).T)
            e, a, b, rs, L = e[L < 3 * rs], a[L < 3 * rs], b[L < 3 * rs], rs[L < 3 * rs], L[L < 3 * rs]
        if len(e):
            t = np.linspace(0, 1, 257)                             # ~0.05 px steps
            px = a[:, None, :] + (b - a)[:, None, :] * t[None, :, None]
            v = ndimage.map_coordinates(ink, [px[..., 1].ravel(), px[..., 0].ravel()], order=1).reshape(len(e), -1)
            other = (v <= 0.5) if pol == 1 else (v > 0.5)          # the ground between the two marks
            gap = other.mean(axis=1) * L
            # each mark's own extent along the centre line (r for a dot, the apothem for facing hexagons)
            ra = np.argmax(other, axis=1) / (len(t) - 1) * L
            rb = np.argmax(other[:, ::-1], axis=1) / (len(t) - 1) * L
            ext = np.where(other.any(axis=1), ra + rb, rs)
            ok = cov(((a + b) / 2)[:, 0]) >= touch
            with np.errstate(divide="ignore"):
                g = np.where(ok, np.inf, gap / ext)
            np.minimum.at(ratio, sel[e[:, 0]], g); np.minimum.at(ratio, sel[e[:, 1]], g)
        lab = labels[pol]
        rest = (lab > 0) & ~np.isin(lab, ids[pol])
        dist = ndimage.distance_transform_edt(~rest)
        d = np.asarray(ndimage.minimum(dist, lab, ids[pol]))
        g = np.maximum(d - 1, 0) / (2 * m[:, 2])
        ok = cov(m[:, 0]) >= touch
        ratio[sel] = np.minimum(ratio[sel], np.where(ok, np.inf, g))
    return ratio


def delaunay(xy):
    """Default Qhull; joggled (QJ) only when the points are degenerate (e.g. one column of marks)."""
    try:
        return Delaunay(xy)
    except Exception:
        return Delaunay(xy, qhull_options="QJ")


def psi6(xy):
    """Per-point |psi6| over Delaunay neighbours (NaN on the hull or with long edges) and NN distance."""
    nn = cKDTree(xy).query(xy, k=2)[0][:, 1]
    tri = delaunay(xy)
    nbrs = [set() for _ in xy]
    for s in tri.simplices:
        for a in s:
            nbrs[a].update(s)
    hull = set(tri.convex_hull.ravel())
    psi = np.full(len(xy), np.nan)
    med = np.median(nn)
    for i, nb in enumerate(nbrs):
        nb.discard(i)
        nb = np.array(sorted(nb))
        d = xy[nb] - xy[i]
        if i in hull or len(nb) < 4 or np.hypot(*d.T).max() > 3 * med:
            continue
        psi[i] = abs(np.exp(6j * np.arctan2(d[:, 1], d[:, 0])).mean())
    return psi, nn


def order_bands(marks, psi, nn, x0, x1):
    """Per 32 px band of marks (dots and holes together): centre x, mean |psi6|, 1 - CV(NN), median r, CV(r),
    mark count, hole fraction, and the standard errors of the mean |psi6| and of CV(NN) (see ORDER_NOISE_SE)."""
    if len(marks) < 8:
        return np.zeros((0, 9))
    xy = marks[:, :2]
    lo, hi = np.percentile(xy[:, 0], [1, 99])
    lo, hi = max(lo, x0), min(hi, x1)
    rows = []
    for b0 in np.arange(lo, hi, ORDER_BAND_PX):
        sel = (xy[:, 0] >= b0) & (xy[:, 0] < b0 + ORDER_BAND_PX)
        if sel.sum() < ORDER_MIN_DOTS:
            continue
        p = psi[sel][~np.isnan(psi[sel])]
        r = marks[sel, 2]
        cv = nn[sel].std() / nn[sel].mean()
        rows.append([b0 + ORDER_BAND_PX / 2, p.mean() if len(p) else np.nan, 1 - cv, np.median(r), r.std() / r.mean(),
                     sel.sum(), (marks[sel, 3] < 0).mean(), p.std() / math.sqrt(len(p)) if len(p) > 1 else 0.0,
                     cv * math.sqrt((0.5 + cv ** 2) / sel.sum())])
    return np.array(rows) if rows else np.zeros((0, 9))


def flip_metrics(marks, psi, nn, pitch):
    """Dots -> holes flip. Returns None (no flip) or (flip x, mix width in pitches, continuity step, note)."""
    dots, holes = marks[:, 3] > 0, marks[:, 3] < 0
    if dots.sum() < ORDER_MIN_DOTS or holes.sum() < ORDER_MIN_DOTS:
        return None
    hi_dot, lo_hole = np.percentile(marks[dots, 0], 95), np.percentile(marks[holes, 0], 5)
    mix = max(hi_dot - lo_hole, 0) / pitch
    # the flip: where the hole fraction, in windows of one pitch, first reaches 1/2
    xs = np.arange(marks[:, 0].min(), marks[:, 0].max(), 1.0)
    frac = np.array([(marks[(marks[:, 0] >= x) & (marks[:, 0] < x + pitch), 3] < 0).mean()
                     if ((marks[:, 0] >= x) & (marks[:, 0] < x + pitch)).any() else 0 for x in xs])
    xf = float(xs[np.argmax(frac >= 0.5)] + pitch / 2)
    side = lambda m: m & (np.abs(marks[:, 0] - xf) <= 2 * pitch)
    d, h = side(dots), side(holes)
    if d.sum() < 3 or h.sum() < 3:
        return xf, mix, 1.0, "fewer than 3 marks on one side of the flip"
    p_d, p_h = np.median(nn[d]), np.median(nn[h])
    r_d, r_h = np.median(marks[d, 2]), np.median(marks[h, 2])
    s_d, s_h = np.nanmean(psi[d]) if (~np.isnan(psi[d])).any() else 0, np.nanmean(psi[h]) if (~np.isnan(psi[h])).any() else 0
    steps = {"pitch": abs(p_d - p_h) / max(p_d, p_h), "radius": abs(r_d - r_h) / max(r_d, r_h), "|psi6|": abs(s_d - s_h)}
    worst = max(steps, key=steps.get)
    note = f"dots->holes: pitch {p_d:.1f}->{p_h:.1f}, r {r_d:.1f}->{r_h:.1f}, |psi6| {s_d:.2f}->{s_h:.2f}; worst {worst}"
    return xf, mix, steps[worst], note


def band_scale(marks, nn):
    """Per mark, l = the median NN distance of the marks within half a band (16 px) of it along the axis."""
    x = marks[:, 0]
    o = np.argsort(x)
    lo = np.searchsorted(x[o], x - ORDER_BAND_PX / 2)
    hi = np.searchsorted(x[o], x + ORDER_BAND_PX / 2)
    return np.array([np.median(nn[o[a:b]]) for a, b in zip(lo, hi)])


def stochastic_spacing(marks, nn, x0, x1):
    """Blue-noise evenness of the marks between x0 and x1 (the ramp). Returns (clumped %, clumped xy,
    max void / l, void x, void y): clumped = NN distance < CLUMP_RATIO * l; void = the largest Delaunay circumcircle
    (an empty circle) whose centre lies inside the marks' extent by at least l, with no vertex on the hull."""
    if len(marks) < 8:
        return 0.0, np.zeros((0, 2)), 0.0, float(x0), float(TILE / 2)
    l = band_scale(marks, nn)
    inr = (marks[:, 0] >= x0) & (marks[:, 0] < x1)
    cl = inr & (nn < CLUMP_RATIO * l)
    xy = marks[:, :2]
    tri = delaunay(xy)
    P = xy[tri.simplices]                                   # (n, 3, 2)
    a, b, c = P[:, 0], P[:, 1], P[:, 2]
    d = 2 * (a[:, 0] * (b[:, 1] - c[:, 1]) + b[:, 0] * (c[:, 1] - a[:, 1]) + c[:, 0] * (a[:, 1] - b[:, 1]))
    sq = lambda p: (p ** 2).sum(axis=1)
    with np.errstate(divide="ignore", invalid="ignore"):
        ux = (sq(a) * (b[:, 1] - c[:, 1]) + sq(b) * (c[:, 1] - a[:, 1]) + sq(c) * (a[:, 1] - b[:, 1])) / d
        uy = (sq(a) * (c[:, 0] - b[:, 0]) + sq(b) * (a[:, 0] - c[:, 0]) + sq(c) * (b[:, 0] - a[:, 0])) / d
    R = np.hypot(ux - a[:, 0], uy - a[:, 1])
    hull = np.zeros(len(xy), bool); hull[tri.convex_hull.ravel()] = True
    lc = np.interp(ux, np.sort(marks[:, 0]), l[np.argsort(marks[:, 0])])
    (mx0, my0), (mx1, my1) = xy.min(axis=0), xy.max(axis=0)
    ok = (~hull[tri.simplices].any(axis=1) & np.isfinite(R) & (ux >= max(x0, mx0) + lc) & (ux <= min(x1, mx1) - lc)
          & (uy >= my0 + lc) & (uy <= my1 - lc))
    if not ok.any():
        return 100 * cl.sum() / max(inr.sum(), 1), xy[cl], 0.0, float(x0), float(TILE / 2)
    v = np.where(ok, R / lc, 0)
    j = int(np.argmax(v))
    return 100 * cl.sum() / max(inr.sum(), 1), xy[cl], float(v[j]), float(ux[j]), float(uy[j])


def closing_hole_bands(holes):
    """Holes in the closing zone, per 32 px band with >= ORDER_MIN_DOTS of them: centre x, median r, CV(r),
    1 - CV(NN) (NN among the closing holes)."""
    if len(holes) < ORDER_MIN_DOTS:
        return np.zeros((0, 4))
    nn = cKDTree(holes[:, :2]).query(holes[:, :2], k=2)[0][:, 1]
    rows = []
    for b0 in np.arange(holes[:, 0].min(), holes[:, 0].max() + 1, ORDER_BAND_PX):
        sel = (holes[:, 0] >= b0) & (holes[:, 0] < b0 + ORDER_BAND_PX)
        if sel.sum() >= ORDER_MIN_DOTS:
            r = holes[sel, 2]
            rows.append([b0 + ORDER_BAND_PX / 2, np.median(r), r.std() / r.mean(), 1 - nn[sel].std() / nn[sel].mean()])
    return np.array(rows) if rows else np.zeros((0, 4))


def higher_is_better(metric):
    return ("min gap" in metric or "polarity mix" in metric or "floor" in metric
            or metric.startswith(("gap: min", "small: min peak", "small: separated", "small: settled",
                                  "stroke: thinnest", "gap: thinnest", "small: smallest surviving")))


# ---------------------------------------------------------------- profiles
def profile(ink, y0, y1, sigma):
    band = ink[y0:y1]
    if sigma:
        band = ndimage.gaussian_filter(band, sigma)
    return band.mean(axis=0)


def silhouette(ink):
    """The filled mark silhouette: convex hull of the ink (the card outline for a card)."""
    from matplotlib.path import Path as MPath
    from scipy.spatial import ConvexHull
    pts = np.argwhere(ink > 0.5)[:, ::-1].astype(float)
    hull = pts[ConvexHull(pts).vertices]
    yy, xx = np.mgrid[:TILE, :TILE]
    inside = MPath(hull).contains_points(np.column_stack([xx.ravel(), yy.ravel()]), radius=1.0)
    return inside.reshape(TILE, TILE).astype(float)


def local_coverage(ink, mask, y0, y1, sigma):
    """Coverage profile along the axis inside the silhouette only (normalised convolution:
    blur(ink*mask) / blur(mask)), so marks at the card's edge aren't diluted by the background."""
    num = ndimage.gaussian_filter(ink * mask, sigma)[y0:y1].sum(axis=0)
    den = ndimage.gaussian_filter(mask, sigma)[y0:y1].sum(axis=0)
    return np.where(den > 1e-3 * (y1 - y0), num / np.maximum(den, 1e-9), 0.0)


def closing_metrics(ink, covn, y0, y1, x0, x1):
    """Closing zone = columns from local coverage >= CLOSING_COVERAGE to the plateau. Returns None or
    (a, b, excess grey %, raw grey %, thin-wall %, worst x, worst y, thin mask)."""
    c = covn[x0:x1]
    if not (c >= CLOSING_COVERAGE).any():
        return None
    a = x0 + int(np.argmax(c >= CLOSING_COVERAGE))
    b = max(x0 + int(np.argmax(c >= PLATEAU * c.max())), a + 2)
    zone = ink[y0:y1, a:b]
    grey = (zone > GREY_INK[0]) & (zone < GREY_INK[1])
    edge = (ndimage.maximum_filter(ink >= 0.9, 3) & ndimage.maximum_filter(ink <= 0.1, 3))[y0:y1, a:b]
    excess = grey & ~edge
    # hairlines: on a 4x upsampled copy, a wall is thin if a disk just under THIN_WALL_PX (so a 2 px wall passes
    # at any sub-pixel phase) doesn't fit: grey top-hat > 0.25 (a dim sub-pixel wall counts); only connected runs at
    # least HAIRLINE_MIN_LEN long are walls (a corner tip or the last speck of a closing hole is not)
    U, pad = 4, 8
    sub = ink[y0:y1, max(a - pad, 0):b + pad]
    up = ndimage.zoom(sub, U, order=1)
    rad = (THIN_WALL_PX * U - 1) / 2
    k = int(rad)
    yy, xx = np.mgrid[-k:k + 1, -k:k + 1]
    disk = xx ** 2 + yy ** 2 <= rad ** 2 + 0.25
    thin = np.zeros(sub.shape, bool)
    for f in (up, 1 - up):                             # ink walls, paper walls
        th = (f - ndimage.grey_opening(f, footprint=disk)) > 0.25
        thin |= th[:sub.shape[0] * U, :sub.shape[1] * U].reshape(sub.shape[0], U, sub.shape[1], U).any(axis=(1, 3))
    lab, n = ndimage.label(thin, np.ones((3, 3)))
    if n:
        ext = np.array([max(s[0].stop - s[0].start, s[1].stop - s[1].start) for s in ndimage.find_objects(lab)])
        thin = np.isin(lab, 1 + np.nonzero(ext >= HAIRLINE_MIN_LEN)[0])
    off = a - max(a - pad, 0)
    thin = thin[:, off:off + b - a]
    bad = excess | thin
    if bad.any():
        dens = ndimage.uniform_filter(bad.astype(float), 16)
        wy, wx = np.unravel_index(int(np.argmax(dens)), dens.shape)
    else:
        wy, wx = (y1 - y0) // 2, 0
    return a, b, excess.mean() * 100, grey.mean() * 100, thin.mean() * 100, a + wx, y0 + wy, thin


def front_metrics(ink, mask, covp, pitch, y0, y1, x0, x1, stochastic=False):
    """The front into the solid. Returns None (no solid front) or (swing px, std px, worst x, worst y,
    raw step per 2 px, raw step x). stochastic: the raw profile is boxed over 2 pitches (no lattice period)."""
    h = y1 - y0
    fr0, fr1 = int(y0 + h * (1 - FRONT_ROW_BAND) / 2), int(y1 - h * (1 - FRONT_ROW_BAND) / 2)
    c = covp[x0:x1]
    xp = x0 + int(np.argmax(c >= PLATEAU * c.max()))
    xs = min(int(xp + 2 * pitch), x1 - 2)
    rows = np.arange(fr0, fr1)
    F = np.full(len(rows), np.nan)
    n = int(pitch) | 1                                 # one-pitch box inside the silhouette: closing holes and the
    solid = ndimage.uniform_filter(ink * mask, n) >= PLATEAU * np.maximum(ndimage.uniform_filter(mask, n), 1e-9)  # card edge don't break it
    for k, y in enumerate(rows):
        row = solid[y, :xs + 1]
        if row[xs]:
            gaps = np.nonzero(~row)[0]
            F[k] = gaps.max() + 1 if len(gaps) else 0
    ok = ~np.isnan(F)
    if ok.mean() < 0.5:
        return None
    sm = ndimage.uniform_filter1d(F[ok], int(3 * pitch) | 1, mode="nearest")   # mean: averages the lattice zigzag
    j = int(np.argmax(np.abs(sm - np.median(sm))))
    swing, std = float(sm.max() - sm.min()), float(sm.std())
    # raw step: 1 px profile over the same rows, boxed over one lattice period (autocorrelation peak in
    # 0.4..1.2 pitch over the closing stretch), sampled every 2 px, from coverage 0.5 to past the front
    raw = ink[fr0:fr1].mean(axis=0)
    lo = x0 + int(np.argmax(c >= CLOSING_COVERAGE)) if (c >= CLOSING_COVERAGE).any() else int(np.nanmin(F))
    hi = int(min(np.nanmax(F) + pitch, x1 - 1))
    seg = raw[lo:hi] - ndimage.uniform_filter1d(raw[lo:hi], int(2 * pitch) | 1)
    lags = np.arange(max(2, int(0.4 * pitch)), int(1.2 * pitch) + 1)
    period = int(pitch)
    if stochastic:
        period = int(2 * pitch)
    elif len(seg) > 3 * pitch:
        ac = [np.dot(seg[:-L], seg[L:]) / (len(seg) - L) for L in lags]
        period = int(lags[int(np.argmax(ac))])
    box = ndimage.uniform_filter1d(raw, period)
    cols = np.arange(lo, hi, 2)
    st = np.abs(np.diff(box[cols])) if len(cols) > 1 else np.zeros(1)
    i = int(np.argmax(st))
    return swing, std, float(sm[j]), float(rows[ok][j]), float(st[i]), float(cols[min(i, len(cols) - 1)] + 1)


def hole_area_front(ink, mask, y0, y1, x1):
    """Stochastic front: the middle FRONT_ROW_BAND of the height in FRONT_STRIP_PX strips; per strip, the paper
    fraction (inside the silhouette) per 8 px column; the strip's front = the end of the last column with paper >=
    FRONT_HOLE_FRAC. Returns (max - min of the fronts, furthest x, its strip's centre y)."""
    h = y1 - y0
    F, Y = [], []
    for s0 in range(int(y0 + h * (1 - FRONT_ROW_BAND) / 2), int(y1 - h * (1 - FRONT_ROW_BAND) / 2) - FRONT_STRIP_PX + 1,
                    FRONT_STRIP_PX):
        m = mask[s0:s0 + FRONT_STRIP_PX]
        pap = ((1 - ink[s0:s0 + FRONT_STRIP_PX]) * m).sum(axis=0) / np.maximum(m.sum(axis=0), 1)
        n = (x1 - COL_PX) // COL_PX * COL_PX
        cols = pap[:n].reshape(-1, COL_PX).mean(axis=1)
        above = np.nonzero(cols >= FRONT_HOLE_FRAC)[0]
        F.append(float((above.max() + 1) * COL_PX) if len(above) else 0.0)
        Y.append(s0 + FRONT_STRIP_PX / 2)
    if len(F) < 2:
        return 0.0, float(x1), float((y0 + y1) / 2)
    F = np.array(F)
    j = int(np.argmax(np.abs(F - np.median(F))))
    return float(F.max() - F.min()), F[j], Y[j]


def edge_spread(small, size, y0, y1, x0, x1):
    """Perceived image at `size` px: per column, the std across the rows (middle 70% of the mark's height) of the
    ink; max over columns whose mean is in [EDGE_MIN_COVERAGE, 0.99). Returns (value, x at 1024)."""
    k = TILE / size
    h = y1 - y0
    r0, r1 = int((y0 + 0.15 * h) / k) + 1, int((y1 - 0.15 * h) / k) - 1
    c0, c1 = int(x0 / k) + 1, int(x1 / k) - 1
    band = small[r0:r1, c0:c1]
    m, s = band.mean(axis=0), band.std(axis=0)
    sel = (m >= EDGE_MIN_COVERAGE) & (m < 0.99)
    if not sel.any():
        return 0.0, float(x1)
    j = int(np.argmax(np.where(sel, s, -1)))
    return float(s[j]), (c0 + j + 0.5) * k


def na(metric, limit, why):
    """A metric with nothing to measure: reported N/A, neither a pass nor a fail."""
    return (metric, float("nan"), limit, True, f"N/A: {why}")


def fmt(v):
    return "     N/A" if v != v else f"{v:>8.3f}"


def default_out(path):
    """$TMPDIR/design-review/<render's folder>/<stem>-review.png. The folder is named after the render's last
    folders (e.g. explorations-round11-a, round11-a-frames), so variants with the same file names don't overwrite each other."""
    parent = Path(path).resolve().parent
    return Path(tempfile.gettempdir()) / "design-review" / "-".join(parent.parts[-3:]) / f"{Path(path).stem}-review.png"


def ramp_metrics(p):
    """p: coverage per column. Returns (i0, i1, steps, drawdown, d2) over the ramp i0..i1 inclusive."""
    i0 = int(np.argmax(p > 0.01))
    i1 = int(np.argmax(p >= PLATEAU * p.max()))
    r = p[i0:i1 + 1]
    steps = np.abs(np.diff(r))
    draw = np.maximum.accumulate(r) - r
    d2 = np.abs(np.diff(r, 2)) if len(r) > 2 else np.zeros(0)
    return i0, i1, steps, draw, d2


# ---------------------------------------------------------------- review
def review(path, axis="x", region=None, out=None, home=False, quiet=False, frame=False, screen="lattice"):
    """Prints the report (or, quiet, nothing) and writes the sheet. Returns (fail count, results).
    frame: an animation frame; the optical centre is reported but not counted (a fill moves the ink centroid).
    screen: "lattice" (order must rise to a hex lattice) or "stochastic" (blue noise: order must stay even)."""
    touch = TOUCH_OK_COVERAGE if screen == "lattice" else TOUCH_OK_COVERAGE_STOCHASTIC
    img, rgb, circles = load(path, axis)
    ink, bg, inkc = ink_map(rgb)
    if (ink > 0.5).sum() < 3 * MIN_MEASURE_MARKS:     # blank or a few specks (an animation's first frame)
        return nothing_measured(path, quiet, f"{int((ink > 0.5).sum())} ink px")
    if region:
        x0, y0, x1, y1 = region if axis == "x" else (region[1], region[0], region[3], region[2])
    else:
        ys, xs = np.nonzero(ink > 0.5)
        x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    h = y1 - y0
    ry0, ry1 = int(y0 + h * (1 - ROW_BAND) / 2), int(y1 - h * (1 - ROW_BAND) / 2)

    # direction: make "rising" left to right
    raw = profile(ink, ry0, ry1, 0)[x0:x1]
    flip = raw[: len(raw) // 3].mean() > raw[-len(raw) // 3:].mean()
    if flip:
        ink = ink[:, ::-1]
        x0, x1 = TILE - x1, TILE - x0
        if circles is not None:
            circles = circles.copy(); circles[:, 0] = TILE - circles[:, 0]
    marks, labels, ids = detect_marks(ink, circles)
    in_rows = (marks[:, 1] >= y0) & (marks[:, 1] < y1) if len(marks) else np.zeros(0, bool)
    if in_rows.sum() < MIN_MEASURE_MARKS and ink.mean() < 0.01:   # near-empty: a few grains, no solid
        return nothing_measured(path, quiet, f"{int(in_rows.sum())} marks, ink {ink.mean():.2%} of the tile")
    pitch = float(np.median(cKDTree(marks[in_rows, :2]).query(marks[in_rows, :2], k=2)[0][:, 1])) if in_rows.sum() > 8 else 4.0
    sigma = max(4.0, pitch)
    # local coverage = the grain-blurred coverage profile along the axis (middle rows, so the paper around the
    # card's edges doesn't dilute it)
    covp = profile(ink, ry0, ry1, sigma)
    # local coverage for the touching exemption and the closing zone: inside the silhouette only
    mask = silhouette(ink)
    covn = local_coverage(ink, mask, ry0, ry1, sigma)
    cov = lambda x: covn[np.clip(np.asarray(x).astype(int), 0, TILE - 1)]
    gaps = mark_gaps(ink, marks, labels, ids, cov, touch)
    mcov = cov(marks[:, 0])
    merged_xy = marks[(marks[:, 4] > 0) & (mcov < touch), :2]
    merged = len(merged_xy)
    detected = marks[in_rows]                          # every mark, for the "nothing measured" guard
    # where marks may touch (coverage >= touch) dots are judged by coverage only; holes are measured on their own
    # (closing: hole ...), not stitched into the dot order bands (a web closing puts them on the cell corners)
    closing_dots = int((in_rows & (mcov >= touch) & (marks[:, 3] > 0)).sum())
    choles = marks[in_rows & (mcov >= touch) & (marks[:, 3] < 0)]
    keep = in_rows & (mcov < touch)
    marks, gaps = marks[keep], gaps[keep]

    results, curves = [], {}
    # 1. coverage profile at 1024, sampled every 8 px
    full = covp
    cols = np.arange(x0, x1 - COL_PX + 1, COL_PX)
    p = np.array([full[c:c + COL_PX].mean() for c in cols])
    rawc = np.array([profile(ink, ry0, ry1, 0)[c:c + COL_PX].mean() for c in cols])
    curves[1024] = (cols + COL_PX / 2, p, rawc, ramp_metrics(p))
    # 2. perceived at 58 / 29 px
    work = Image.fromarray((np.clip(ink, 0, 1) * 255).astype(np.uint8)).convert("RGB")  # 0 = bg, 255 = ink
    previews, smalls = {}, {}
    for size in (58, 29):
        previews[size] = img.resize((size, size), Image.BOX)
        small = np.asarray(work.resize((size, size), Image.BOX), dtype=float)[:, :, 0] / 255
        small = smalls[size] = ndimage.gaussian_filter(small, PERCEIVED_BLUR)
        k = TILE / size
        sp = profile(small, int(ry0 / k), max(int(ry0 / k) + 1, int(round(ry1 / k))), 0)
        lo, hi = int(x0 / k), int(math.ceil(x1 / k))
        curves[size] = ((np.arange(lo, hi) + 0.5) * k, sp[lo:hi], None, ramp_metrics(sp[lo:hi]))
    bad_x = []
    for size, (xs_, prof, _, (i0, i1, steps, draw, d2)) in curves.items():
        lim = PROFILE_LIMITS[size]
        unit = "8 px" if size == 1024 else "px"
        for name, arr, limit, off in (("max |step|", steps, lim[0], 0.5), ("max drawdown", draw, lim[1], 0),
                                      ("max |2nd diff|", d2, lim[2], 1)):
            if not len(arr):                           # a ramp of one column (a near-empty frame)
                results.append(na(f"coverage {size:>4} {name} / {unit}", limit, "the ramp is under 3 columns"))
                continue
            j = int(np.argmax(arr))
            xs_at = float(np.interp(i0 + j + off, np.arange(len(xs_)), xs_))
            ok = arr[j] <= limit
            results.append((f"coverage {size:>4} {name} / {unit}", arr[j], limit, ok, xs_at))
            for jj in np.nonzero(arr > limit)[0]:
                bad_x.append(float(np.interp(i0 + jj + off, np.arange(len(xs_)), xs_)))
    i0, i1 = curves[1024][3][:2]
    ramp = (curves[1024][0][i0] - COL_PX / 2, curves[1024][0][i1] + COL_PX / 2)

    def at(x, y=None):
        """A spot in the analysis frame -> 'at x 385, y 535 (band 5)' in the render's own 1024 px coordinates;
        band = 32 px band counted from the start of the ramp (where ink starts rising)."""
        band = f" (band {int((x - ramp[0]) // ORDER_BAND_PX)})" if ramp[0] <= x < ramp[1] + ORDER_BAND_PX else ""
        xi = x_report(x, flip)
        if y is None:
            return f"at {axis} {xi:.0f}{band}"
        px, py = (xi, y) if axis == "x" else (y, xi)
        return f"at x {px:.0f}, y {py:.0f}{band}"
    bad_pts = []                                       # (x, y) failing marks, circled on the sheet

    results = [(m, v, lim, ok, note if isinstance(note, str) else at(note)) for m, v, lim, ok, note in results]   # coverage spots, now with bands

    # 0. guard: every band of intermediate coverage holds detected marks (nothing measured is not a pass)
    empty = []
    for b0 in np.arange(ramp[0], ramp[1], ORDER_BAND_PX):
        cb = covn[int(b0):int(b0) + ORDER_BAND_PX].mean()
        if MARKS_MIN_COVERAGE[0] <= cb < MARKS_MIN_COVERAGE[1] and not (
                (detected[:, 0] >= b0) & (detected[:, 0] < b0 + ORDER_BAND_PX)).any():
            empty.append(b0 + ORDER_BAND_PX / 2)
    results.append(("marks: empty coverage bands", len(empty), 0, not empty,
                    f"{ORDER_BAND_PX} px bands with local coverage {MARKS_MIN_COVERAGE[0]}-{MARKS_MIN_COVERAGE[1]} "
                    "and no detected mark" + (f"; first {at(empty[0])}" if empty else "")))
    bad_x += empty

    # 3. order along the axis
    psi, nn = psi6(marks[:, :2]) if len(marks) >= 8 else (np.zeros(0), np.zeros(0))
    bands = order_bands(marks, psi, nn, ramp[0], ramp[1])
    for col, name in ((1, "order |psi6|"), (2, "order 1-CV(NN)")):
        v = bands[:, col] if len(bands) else np.zeros(0)
        v = v[~np.isnan(v)]
        if len(v) < 2:
            if screen == "lattice":
                results.append((f"{name} band step", 0, ORDER_MAX_STEP, True, "fewer than 2 mark bands"))
            results.append((f"{name} drawdown", 0, ORDER_DRAWDOWN, True, "fewer than 2 mark bands"))
            continue
        bx_ = bands[~np.isnan(bands[:, col]), 0]
        se = bands[~np.isnan(bands[:, col]), 6 + col]          # standard error per band (columns 7, 8)
        raw = np.abs(np.diff(v))
        st = np.maximum(raw - ORDER_NOISE_SE * np.hypot(se[1:], se[:-1]), 0)
        top = np.array([int(np.argmax(v[:i + 1])) for i in range(len(v))])   # the running max's band
        rawdd = v[top] - v
        dd = np.maximum(rawdd - ORDER_NOISE_SE * np.hypot(se[top], se) * (top != np.arange(len(v))), 0)
        j, k = int(np.argmax(st)), int(np.argmax(dd))
        span = (f"{v.min():.2f} -> {v.max():.2f}, {len(v)} bands of {ORDER_BAND_PX} px, minus {ORDER_NOISE_SE:g} SE "
                f"(raw max step {raw.max():.2f}, drawdown {rawdd.max():.2f})")
        if screen == "lattice":
            results.append((f"{name} band step", st[j], ORDER_MAX_STEP, st[j] <= ORDER_MAX_STEP,
                            f"{span}; worst " + at(bx_[j] + ORDER_BAND_PX / 2)))
            bad_x += [float(bx_[i] + ORDER_BAND_PX / 2) for i in np.nonzero(st > ORDER_MAX_STEP)[0]]
        info = screen == "stochastic" and col == 1         # blue noise: |psi6| ~0.3-0.5 per band by design, noisy
        results.append((f"{name} drawdown", dd.max(), ORDER_DRAWDOWN, info or dd.max() <= ORDER_DRAWDOWN,
                        ("INFO, not counted on a stochastic screen; " if info else "")
                        + (f"must rise (raw {rawdd.max():.2f} minus {ORDER_NOISE_SE:g} SE)" if screen == "lattice" else f"must not fall; {span}") + "; worst " + at(bx_[k])))
        if not info:
            bad_x += [float(bx_[i]) for i in np.nonzero(dd > ORDER_DRAWDOWN)[0]]
    if screen == "stochastic":                        # evenly spaced: no clumps, no voids, regularity above a floor
        v = bands[:, 2] if len(bands) else np.ones(1)
        j = int(np.argmin(v))
        results.append(("order 1-CV(NN) floor", v[j], NN_FLOOR_STOCHASTIC, v[j] >= NN_FLOOR_STOCHASTIC,
                        "blue noise ~0.8, uniform random ~0.5" + (f"; lowest {at(bands[j, 0])}" if len(bands) else "")))
        if len(bands) and v[j] < NN_FLOOR_STOCHASTIC:
            bad_x.append(float(bands[j, 0]))
        clump, cxy, void, vx, vy = stochastic_spacing(marks, nn, ramp[0], ramp[1])
        results.append(("stochastic: clumped marks %", clump, CLUMP_MAX, clump <= CLUMP_MAX,
                        f"NN < {CLUMP_RATIO} x the band's median NN (g(r) below the min distance)"
                        + (f"; first {at(*cxy[0])}" if len(cxy) else "")))
        results.append(("stochastic: max void / NN", void, VOID_MAX, void <= VOID_MAX,
                        f"largest empty circle radius / the band's median NN; {at(vx, vy)}"))
        if clump > CLUMP_MAX:
            bad_pts += [tuple(p_) for p_ in cxy]
        if void > VOID_MAX:
            bad_pts.append((vx, vy))

    # 4. seam: dots -> holes flip
    flip_x = None
    fm = flip_metrics(marks, psi, nn, pitch) if len(marks) >= 8 else None
    if fm is None:
        why = f"no dots -> holes flip below coverage {touch} ({len(choles)} closing holes: see closing: hole ...)"
        results.append(("seam: polarity mix / pitch", POLARITY_MIN_MIX, POLARITY_MIN_MIX, True, why))
        results.append(("seam: flip continuity step", 0, FLIP_STEP_MAX, True, why))
    else:
        flip_x, mix, step, note = fm
        results.append(("seam: polarity mix / pitch", mix, POLARITY_MIN_MIX, mix >= POLARITY_MIN_MIX,
                        f"flip {at(flip_x)}, pitch {pitch:.1f} px"))
        results.append(("seam: flip continuity step", step, FLIP_STEP_MAX, step <= FLIP_STEP_MAX, f"{at(flip_x)}: {note}"))
        if mix < POLARITY_MIN_MIX or step > FLIP_STEP_MAX:
            bad_x.append(flip_x)

    # 5. closing zone: grey mush and hairline walls
    cm = closing_metrics(ink, covn, ry0, ry1, x0, x1)
    if cm is None:
        results.append(("closing: grey px (not AA edge) %", 0, GREY_EXCESS_MAX, True, f"no zone with coverage >= {CLOSING_COVERAGE}"))
        results.append(("closing: hairline walls < 2 px %", 0, THIN_WALL_MAX, True, f"no zone with coverage >= {CLOSING_COVERAGE}"))
    else:
        a, b, excess, grey, thin, wx, wy, _ = cm
        zone = f"zone {axis} {min(x_report(a, flip), x_report(b, flip)):.0f}-{max(x_report(a, flip), x_report(b, flip)):.0f}"
        results.append(("closing: grey px (not AA edge) %", excess, GREY_EXCESS_MAX, excess <= GREY_EXCESS_MAX,
                        f"{zone}; all grey (lum 60-200) {grey:.1f}%; densest {at(wx, wy)}"))
        results.append(("closing: hairline walls < 2 px %", thin, THIN_WALL_MAX, thin <= THIN_WALL_MAX,
                        f"{zone}; ink or paper walls < {THIN_WALL_PX:g} px; densest {at(wx, wy)}"))
        if excess > GREY_EXCESS_MAX or thin > THIN_WALL_MAX:
            bad_x.append(float(wx)); bad_pts.append((float(wx), float(wy)))

    # 5b. holes in the closing zone (coverage >= the touching exemption): one size per position, shrinking into the
    # solid, evenly spaced
    hb = closing_hole_bands(choles)
    hole_note = f"{len(choles)} holes at coverage >= {touch}"
    if not len(hb):
        for m_, lim in (("closing: hole size CV within band", SIZE_CV_MAX), ("closing: hole size rise", CLOSING_HOLE_RISE_MAX)):
            results.append((m_, 0, lim, True, f"{hole_note}: fewer than {ORDER_MIN_DOTS} per band"))
        results.append(("closing: hole 1-CV(NN) floor", 1, CLOSING_HOLE_NN_FLOOR, True,
                        f"{hole_note}: fewer than {ORDER_MIN_DOTS} per band"))
    else:
        # a stochastic closing's holes are the random gaps between merging disks: their sizes and spacing vary by
        # design, so these three are INFO there; the hole-area front and the edge spread (6) judge that zone
        info = screen == "stochastic"
        pre = "INFO, not counted on a stochastic screen; " if info else ""
        j = int(np.argmax(hb[:, 2]))
        results.append(("closing: hole size CV within band", hb[j, 2], SIZE_CV_MAX, info or hb[j, 2] <= SIZE_CV_MAX,
                        f"{pre}{hole_note}, {len(hb)} bands; worst {at(hb[j, 0])}"))
        rise = hb[:, 1] - np.minimum.accumulate(hb[:, 1])   # above the smallest hole so far
        k = int(np.argmax(rise))
        rel = rise[k] / hb[:, 1].max()
        results.append(("closing: hole size rise", rel, CLOSING_HOLE_RISE_MAX, info or rel <= CLOSING_HOLE_RISE_MAX,
                        f"{pre}median r {hb[0, 1]:.1f} -> {hb[-1, 1]:.1f} px, must shrink into the solid; worst {at(hb[k, 0])}"))
        f = CLOSING_HOLE_NN_FLOOR
        k2 = int(np.argmin(hb[:, 3]))
        results.append(("closing: hole 1-CV(NN) floor", hb[k2, 3], f, info or hb[k2, 3] >= f, f"{pre}lowest {at(hb[k2, 0])}"))
        if not info:
            bad_x += [float(x) for x in hb[hb[:, 2] > SIZE_CV_MAX, 0]] + [float(hb[k2, 0])] * int(hb[k2, 3] < f)
            if rel > CLOSING_HOLE_RISE_MAX:
                bad_x.append(float(hb[k, 0]))

    # 6. front into the solid: straightness and the unblurred step
    fm2 = front_metrics(ink, mask, covp, pitch, y0, y1, x0, x1, stochastic=screen == "stochastic")
    if screen == "stochastic":                        # per-row swing is large by nature: per-strip hole-area front
        spread, sx, sy = hole_area_front(ink, mask, y0, y1, x1)
        results.append(("front: hole-area front spread px", spread, FRONT_SPREAD_MAX, True,
                        f"INFO, not counted (see FRONT_SPREAD_MAX; edge: row spread judges the edge); where paper < "
                        f"{FRONT_HOLE_FRAC:.0%} for good, per {FRONT_STRIP_PX} px strip of the middle "
                        f"{FRONT_ROW_BAND:.0%}; furthest {at(sx, sy)}"))
    if fm2 is None:
        if screen == "lattice":
            results.append(("front: swing px", 0, FRONT_SWING_MAX, True, "no solid front"))
        results.append(("front: raw step / 2 px", 0, FRONT_RAW_STEP_MAX, True, "no solid front"))
    else:
        swing, fstd, fx, fy, rstep, rx = fm2
        if screen == "lattice":
            results.append(("front: swing px", swing, FRONT_SWING_MAX, swing <= FRONT_SWING_MAX,
                            f"std {fstd:.1f} px over the middle {FRONT_ROW_BAND:.0%} of the height; furthest {at(fx, fy)}"))
        results.append(("front: raw step / 2 px", rstep, FRONT_RAW_STEP_MAX, rstep <= FRONT_RAW_STEP_MAX,
                        f"unblurred, boxed over {'one lattice period' if screen == 'lattice' else '2 pitches'}; worst {at(rx)}"))
        if screen == "lattice" and swing > FRONT_SWING_MAX:
            bad_x.append(fx); bad_pts.append((fx, fy))
        if rstep > FRONT_RAW_STEP_MAX:
            bad_x.append(rx)

    # 6b. edge into the solid as the eye sees it at icon size (both screens: the guard that a looser front metric
    # can't let a ragged edge through): row-to-row spread of perceived coverage where the column is nearly solid
    for size in (58, 29):
        es, ex = edge_spread(smalls[size], size, y0, y1, x0, x1)
        results.append((f"edge: row spread at {size:>2} px", es, EDGE_SPREAD_MAX[size], es <= EDGE_SPREAD_MAX[size],
                        f"std across rows of perceived coverage, columns at >= {EDGE_MIN_COVERAGE} (a ragged edge); "
                        f"worst {at(ex)}"))
        if es > EDGE_SPREAD_MAX[size]:
            bad_x.append(ex)

    # 7. geometry
    results.append(("touching: merged blobs", merged, 0, merged == 0,
                    f"count where coverage < {touch}" + (f"; first {at(*merged_xy[0])}" if merged else "")))
    bad_pts += [tuple(p_) for p_ in merged_xy]
    if np.isfinite(gaps).any():
        j = int(np.argmin(gaps))
        nbad = int((gaps < MIN_GAP_RATIO).sum())
        results.append(("touching: min gap / (r1+r2)", gaps[j], MIN_GAP_RATIO, gaps[j] >= MIN_GAP_RATIO,
                        f"min {at(*marks[j, :2])} ({'hole' if marks[j, 3] < 0 else 'dot'})"
                        + (f"; {nbad} marks below" if nbad else "")))
        bad_pts += [tuple(p_) for p_ in marks[gaps < MIN_GAP_RATIO, :2]]
    w = ink.sum()
    yy, xx = np.mgrid[:TILE, :TILE]
    cx, cy = (ink * xx).sum() / w, (ink * yy).sum() / w
    if flip:
        cx = TILE - cx
    if axis == "y":
        cx, cy = cy, cx
    bx, by = (x0 + x1) / 2, (y0 + y1) / 2
    if flip:
        bx = TILE - bx
    if axis == "y":
        bx, by = by, bx
    ox, oy = (cx + bx) / 2, (cy + by) / 2
    off = max(abs(ox - TILE / 2), abs(oy - TILE / 2)) / TILE
    results.append(("optical centre offset / tile", off, CENTROID_TOL, frame or off <= CENTROID_TOL,
                    ("INFO, not counted on a frame: " if frame and off > CENTROID_TOL else "") + f"centroid ({cx:.0f}, {cy:.0f}), bbox centre ({bx:.0f}, {by:.0f})"))
    # overhang: ink outside the card (solid core) silhouette; the stream left of the card may fill its height only
    solid = ink > 0.5
    core = ndimage.maximum_filter(ndimage.minimum_filter(solid.astype(np.uint8), CARD_CORE_PX), CARD_CORE_PX) > 0
    if core.sum() < CARD_CORE_PX ** 2:
        results.append(na("overhang: farthest ink past the card / px", OVERHANG_PX, "no solid card (under 48 px core)"))
    else:
        cys, cxs = np.nonzero(core)
        cx1, cy0, cy1 = cxs.max() + 1, cys.min(), cys.max() + 1
        ys_, xs_ = np.nonzero(solid)
        past = np.maximum.reduce([cy0 - ys_, ys_ + 1 - cy1, xs_ + 1 - cx1, np.zeros(len(xs_), int)])
        n_out = int((past > 0).sum())
        dist, share = (past.max(), n_out / len(xs_))
        k = int(np.argmax(past))
        results.append(("overhang: farthest ink past the card / px", dist, OVERHANG_PX, dist <= OVERHANG_PX,
                        f"card rows {cy0}-{cy1}, right edge {cx1}" + (f"; worst {at(*(xs_[k], ys_[k]))}" if dist > 0 else "")))
        results.append(("overhang: share of ink outside the card", share, OVERHANG_SHARE, share <= OVERHANG_SHARE,
                        f"{n_out} of {len(xs_)} ink px"))
    # bbox margins in the tile (the ink bbox, not the region); the optical centre above also weighs the centroid
    ys_, xs_ = np.nonzero(solid)
    ml, mr, mt, mb = xs_.min(), TILE - 1 - xs_.max(), ys_.min(), TILE - 1 - ys_.max()
    for nm, a_, b_ in (("left/right", ml, mr), ("top/bottom", mt, mb)):
        imb = abs(a_ - b_) / TILE
        results.append((f"bbox margin imbalance {nm} / tile", imb, BBOX_IMBALANCE, frame or imb <= BBOX_IMBALANCE,
                        ("INFO, not counted on a frame: " if frame and imb > BBOX_IMBALANCE else "") + f"margins {a_} vs {b_} px"))
    if len(bands):
        j = int(np.nanargmax(bands[:, 4]))
        cv = bands[j, 4]
        results.append(("dot size CV within band", cv, SIZE_CV_MAX, cv <= SIZE_CV_MAX,
                        f"r {bands[:, 3].min():.1f} -> {bands[:, 3].max():.1f} px; worst {at(bands[j, 0])}"))
        bad_x += [float(x) for x in bands[bands[:, 4] > SIZE_CV_MAX, 0]]
        rel = np.abs(np.diff(bands[:, 3])) / bands[:, 3].max() if len(bands) > 1 else np.zeros(1)
        j = int(np.argmax(rel))
        results.append(("dot size step between bands", rel.max(), SIZE_STEP_MAX, rel.max() <= SIZE_STEP_MAX,
                        "fraction of max radius" + (f"; worst {at(bands[j, 0] + ORDER_BAND_PX / 2)}" if len(bands) > 1 else "")))
        if len(bands) > 1:
            bad_x += [float(bands[i, 0] + ORDER_BAND_PX / 2) for i in np.nonzero(rel > SIZE_STEP_MAX)[0]]

    # report
    name = Path(path).name
    fails = sum(not r[3] for r in results)
    out = Path(out) if out else default_out(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    home_img = home_mock(img, out.with_name(f"{Path(path).stem}-home.png")) if home else None
    sheet(img, curves, bands, ramp, (ry0, ry1), bad_x, bad_pts, flip, axis, previews, results, out, home_img)
    if quiet:
        return fails, results
    print(f"design-review {name}: screen {screen}, axis {axis}, ink rises {'<-' if flip else '->'}, ramp {axis} "
          f"{x_report(ramp[0], flip):.0f}-{x_report(ramp[1], flip):.0f}; marks below coverage {touch}: {len(marks)} "
          f"({int((marks[:, 3] > 0).sum())} dots, {int((marks[:, 3] < 0).sum())} holes); closing zone: {len(choles)} holes "
          f"measured, {closing_dots} dots judged by coverage only; grain blur sigma {sigma:.1f} px")
    print(f"{'METRIC':<40}{'VALUE':>8}{'LIMIT':>8}  RESULT")
    for m, v, lim, ok, note in results:
        cmp = ">=" if higher_is_better(m) else "<="
        print(f"{m:<40}{fmt(v)}{cmp:>4}{lim:<5.3g} {'N/A ' if v != v else 'PASS' if ok else 'FAIL'}  {note}")
    print(f"RESULT: {'FAIL' if fails else 'PASS'} ({fails} of {len(results)} metrics failed)")
    print(f"sheet: {out}" + (f"\nhome:  {out.with_name(Path(path).stem + '-home.png')}" if home else ""))
    return fails, results


def nothing_measured(path, quiet, why):
    """Too little ink to measure anything: every metric N/A, no sheet. Returns (0 fails, None)."""
    if not quiet:
        print(f"design-review {Path(path).name}: RESULT: N/A, nothing to measure ({why}); no sheet")
    return 0, None


def frame_paths(spec):
    """--frames value: a directory (its *.png and *.svg, sorted) or a glob pattern."""
    import glob
    p = Path(spec)
    if p.is_dir():
        return sorted(str(f) for f in p.iterdir() if f.suffix.lower() in (".png", ".svg"))
    return sorted(glob.glob(spec))


def review_frames(paths, axis, region, home, screen="lattice"):
    """Every metric on every frame; prints one line per frame, then the worst frame per metric (frames or metrics
    with nothing to measure are N/A and skipped). Returns fails."""
    runs = []
    for p in paths:
        fails, results = review(p, axis, region, None, home, quiet=True, frame=True, screen=screen)
        if results is None:
            print(f"frame {Path(p).name}: N/A (nothing to measure)")
            continue
        runs.append((Path(p).name, fails, results))
        bad = ", ".join(m.strip() for m, _, _, ok, _ in results if not ok)
        print(f"frame {Path(p).name}: {'FAIL' if fails else 'PASS'} ({fails} of {len(results)})" + (f": {bad}" if bad else ""))
    print(f"\ndesign-review frames: {len(paths)} frames ({len(paths) - len(runs)} N/A), worst frame per metric")
    if not runs:
        print("RESULT: N/A (nothing to measure on any frame)")
        return 0
    print(f"{'METRIC':<40}{'VALUE':>8}{'LIMIT':>8}  RESULT  FRAME / WHERE")
    metrics = list(dict.fromkeys(r[0] for _, _, res in runs for r in res))
    nfail = 0
    for m in metrics:
        higher = higher_is_better(m)
        rows = [(name, r) for name, _, res in runs for r in res if r[0] == m]
        lim = rows[0][1][2]
        bad = [r for r in rows if not r[1][3]]
        pool = bad or [r for r in rows if r[1][1] == r[1][1]]   # the worst failing frame, else the worst measured value
        if not pool:
            print(f"{m:<40}{fmt(float('nan'))}{'>=' if higher else '<=':>4}{lim:<5.3g} N/A   {rows[0][1][4]}")
            continue
        name, (_, v, _, ok, note) = (min if higher else max)(pool, key=lambda r: r[1][1])
        nfail += not ok
        tail = f" ({len(bad)} of {len(rows)} frames fail)" if bad else ""
        print(f"{m:<40}{v:>8.3f}{'>=' if higher else '<=':>4}{lim:<5.3g} {'PASS' if ok else 'FAIL'}  {name}: {note}{tail}")
    worst = max(runs, key=lambda r: r[1])
    print(f"RESULT: {'FAIL' if nfail else 'PASS'} ({nfail} of {len(metrics)} metrics fail on some frame)")
    print(f"sheets: {default_out(paths[0]).parent}/<frame>-review.png; most failures: "
          f"{default_out(paths[0]).parent / (Path(worst[0]).stem + '-review.png')}")
    return nfail


def watch(paths, run):
    """Re-run whenever a render's mtime changes (poll every 0.5 s); one summary line per run. Ctrl-C stops."""
    import time
    seen = {}
    print(f"watching {', '.join(map(str, paths))} (Ctrl-C to stop)")
    try:
        while True:
            for p in paths:
                m = Path(p).stat().st_mtime if Path(p).exists() else None
                if m is None or seen.get(p) == m:
                    continue
                seen[p] = m
                time.sleep(0.3)                        # let the writer finish
                try:
                    fails, results = run(p)
                    if results is None:
                        print(f"{time.strftime('%H:%M:%S')} {Path(p).name}: N/A (nothing to measure)", flush=True)
                        continue
                    loc = lambda note: (m_.group(0) if (m_ := re.search(r"at (x|y) [^;:]*", note)) else "")
                    bad = "; ".join(f"{n.strip()} {v:.3f} {loc(note)}".rstrip() for n, v, _, ok, note in results if not ok)
                    print(f"{time.strftime('%H:%M:%S')} {Path(p).name}: {'FAIL' if fails else 'PASS'} "
                          f"({fails} of {len(results)})" + (f": {bad}" if bad else ""), flush=True)
                except Exception as e:                 # a half-written file: wait for the next change
                    print(f"{time.strftime('%H:%M:%S')} {Path(p).name}: ERROR {e}", flush=True)
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass


def x_report(x, flip):
    return TILE - x if flip else x


# ---------------------------------------------------------------- outline mode
def outline_dots(ink, circles):
    """Dots (n x 3: x, y, r) of a dotted outline, and how many ink blobs hold more than one dot (merged).
    SVG: its circles, exact. PNG: peaks of the ink's distance transform, strongest first, each kept unless it lies
    inside a kept dot, so two overlapping dots stay two (one blob, two peaks); a blob with one peak is measured by
    its ink-weighted centroid and area (sub-pixel). No size cap: the halftone mode's marks stop at 0.2% of the tile
    (r ~26 px), so the dotcard's 31 px dots and its settled dot were never measured there."""
    lab, n = ndimage.label(ink > 0.5)
    if circles is not None and (circles[:, 2] < OUTLINE_MAX_R * TILE).any():
        dots = circles[circles[:, 2] < OUTLINE_MAX_R * TILE]
    else:
        edt = ndimage.distance_transform_edt(ink > 0.5)
        ys, xs = np.nonzero((edt == ndimage.maximum_filter(edt, 5)) & (edt >= 2))
        kept = []
        for i in np.argsort(-edt[ys, xs], kind="stable"):
            if all(math.hypot(xs[i] - kx, ys[i] - ky) > kr for kx, ky, kr in kept):
                kept.append((float(xs[i]), float(ys[i]), float(edt[ys[i], xs[i]]) + 0.5))
        dots = np.array(kept).reshape(-1, 3)
        comp = lab[dots[:, 1].astype(int), dots[:, 0].astype(int)]
        per = np.bincount(comp, minlength=n + 1)
        for k, c in enumerate(comp):
            if per[c] == 1:
                cy, cx = ndimage.center_of_mass(ink, lab, c)
                dots[k] = cx, cy, math.sqrt(ndimage.sum(ink, lab, c) / math.pi)
    xi = np.clip(dots[:, 0].round().astype(int), 0, TILE - 1)
    yi = np.clip(dots[:, 1].round().astype(int), 0, TILE - 1)
    per = np.bincount(lab[yi, xi], minlength=n + 1)[1:]
    return dots, int((per > 1).sum())


def rounded_rect(cx, cy, a, b, rc, step=0.1):
    """Points every ~step px along a rounded rectangle (centre, half sizes a and b, corner radius rc), clockwise on
    screen (y down) from the bottom-edge centre going left, as dotcard.py walks it."""
    pieces = [("l", (cx, cy + b), (cx - a + rc, cy + b)), ("c", (cx - a + rc, cy + b - rc), 90),
              ("l", (cx - a, cy + b - rc), (cx - a, cy - b + rc)), ("c", (cx - a + rc, cy - b + rc), 180),
              ("l", (cx - a + rc, cy - b), (cx + a - rc, cy - b)), ("c", (cx + a - rc, cy - b + rc), 270),
              ("l", (cx + a, cy - b + rc), (cx + a, cy + b - rc)), ("c", (cx + a - rc, cy + b - rc), 0),
              ("l", (cx + a - rc, cy + b), (cx, cy + b))]
    out = []
    for kind, p0, p1 in pieces:
        if kind == "l":
            m = max(2, int(math.dist(p0, p1) / step))
            out.append(np.linspace(p0, p1, m, endpoint=False))
        else:
            m = max(2, int(math.pi / 2 * rc / step))
            t = np.radians(p1 + np.linspace(0, 90, m, endpoint=False))
            out.append(np.column_stack([p0[0] + rc * np.cos(t), p0[1] + rc * np.sin(t)]))
    return np.concatenate(out)


def fit_outline(xy):
    """The card outline the dot centres sit on: a rounded rectangle whose straight edges run through the dots,
    corner radius on a grid (the largest that fits). Returns (arc position of each dot from the bottom-edge centre, perimeter,
    distance of each dot off the path, (cx, cy, a, b, rc))."""
    lo, hi = xy.min(axis=0), xy.max(axis=0)
    near = 0.1 * (hi - lo)                             # each edge: the median of the dots within 10% of the extreme,
    lo, hi = (np.array([np.median(xy[xy[:, i] <= lo[i] + near[i], i]) for i in (0, 1)]),   # so one dot pushed out
              np.array([np.median(xy[xy[:, i] >= hi[i] - near[i], i]) for i in (0, 1)]))   # doesn't move the edge
    (cx, cy), (a, b) = (lo + hi) / 2, (hi - lo) / 2
    q0 = np.abs(xy - (cx, cy))
    fits = []
    for rc in np.linspace(0, min(a, b), 801):
        q = q0 - (a - rc, b - rc)
        fits.append((rc, np.abs(np.hypot(*np.maximum(q, 0).T) + np.minimum(q.max(axis=1), 0) - rc)))
    # the roundest outline within 0.02 px of the best fit: with no dot on the corner arcs (dotcard --edges 4,6) every
    # radius up to the true one fits exactly, and the dots' spacing is measured along the true one. Fit = the 90th
    # percentile of the dots' distances, so one misplaced dot doesn't bend the outline (it shows as off the path)
    best = min(np.percentile(f[1], 90) for f in fits)
    rc, off = [f for f in fits if np.percentile(f[1], 90) <= best + 0.02][-1]
    poly = rounded_rect(cx, cy, a, b, rc)
    seg = np.hypot(*np.diff(np.vstack([poly, poly[:1]]), axis=0).T)
    s = np.concatenate([[0], np.cumsum(seg)[:-1]])
    return s[cKDTree(poly).query(xy)[1]], seg.sum(), off, (cx, cy, a, b, rc)


def size_clusters(d):
    """Diameters -> cluster id per dot (0 = smallest), split where a sorted diameter is > OUTLINE_CLUSTER_SPLIT x the
    previous one; and the regular cluster (most dots; the bigger one on a tie)."""
    o = np.argsort(d)
    cid = np.zeros(len(d), int)
    cid[o] = np.concatenate([[0], np.cumsum(d[o][1:] / d[o][:-1] > OUTLINE_CLUSTER_SPLIT)])
    counts = np.bincount(cid)
    regular = max(range(len(counts)), key=lambda k: (counts[k], k))
    return cid, regular


def review_outline(path, out=None, home=False, quiet=False, expected=None):
    """Outline mode: a card outline traced by separate dots. Prints the report and writes the sheet; returns
    (fail count, results)."""
    img, rgb, circles = load(path, "x")
    ink, bg, inkc = ink_map(rgb)
    dots, blobs = outline_dots(ink, circles) if (ink > 0.5).any() else (np.zeros((0, 3)), 0)
    if len(dots) < 3:
        return nothing_measured(path, quiet, f"{len(dots)} dots")
    s_, perim, off_, card = fit_outline(dots[:, :2])
    o = np.argsort(s_)                                 # along the path, clockwise from the bottom-edge centre
    big = int(np.argmax(dots[o, 2]))                   # start at the settled dot when there is one
    if dots[o[big], 2] >= OUTLINE_SETTLED_MIN * np.median(dots[:, 2]):
        o = np.roll(o, -big)
    dots, s_, off_ = dots[o], s_[o], off_[o]           # from here on dot k is #k+1 along the path
    n = len(dots)
    lab = lambda k: f"#{k % n + 1}"
    xy, r = dots[:, :2], dots[:, 2]
    nxt = (np.arange(n) + 1) % n
    spacing = (s_[nxt] - s_) % perim                   # arc length along the fitted outline
    gap = np.hypot(*(xy[nxt] - xy).T) - r - r[nxt]     # the visible gap: straight line between the edges
    pitch = perim / n
    results, bad_pairs, worst_pairs = [], [], []
    fromsvg = circles is not None and (circles[:, 2] < OUTLINE_MAX_R * TILE).any()

    # count
    if expected:
        results.append(("dots: count", n, expected, n == expected, f"expected {expected} (--dots)"))
    else:
        results.append(("dots: count", n, float("nan"), True, "INFO: report only (pass --dots N to check)"))

    # spacing along the path (centre to centre, path neighbours)
    dev = np.abs(spacing - pitch) / pitch
    cv = spacing.std() / pitch
    j = int(np.argmax(dev))
    pair = f"{lab(j)}-{lab(j + 1)} {spacing[j]:.1f} px"
    results.append(("spacing: CV", cv, OUTLINE_SPACING_CV, cv <= OUTLINE_SPACING_CV,
                    f"arc length along the fitted card outline ({2 * card[2]:.0f} x {2 * card[3]:.0f} px, corner "
                    f"radius {card[4]:.1f} px), mean {pitch:.1f} px over {n} pairs"))
    results.append(("spacing: max deviation / mean", dev[j], OUTLINE_SPACING_DEV, dev[j] <= OUTLINE_SPACING_DEV,
                    f"worst {pair}"))
    worst_pairs += [j] + [int(k) for k in np.nonzero(dev > OUTLINE_SPACING_DEV)[0]]
    k = int(np.argmax(off_))
    results.append(("path: max distance off the outline px", off_[k], OUTLINE_OFFPATH_PX, off_[k] <= OUTLINE_OFFPATH_PX,
                    f"dot centre to the fitted rounded rectangle; worst {lab(k)}"))

    # edge gaps: any two dots (an extra or misplaced dot may touch a non-neighbour), then neighbours by size cluster
    dd = np.hypot(*(xy[:, None] - xy[None]).T) - r[:, None] - r[None]
    dd[np.triu_indices(n)] = np.inf
    a_, b_ = np.unravel_index(np.argmin(dd), dd.shape)
    low = sorted(zip(*np.nonzero(dd < OUTLINE_MIN_GAP_PX)), key=lambda p: dd[p])
    words = lambda g: f"overlap {-g:.1f} px" if g <= 0 else f"gap {g:.1f} px"
    note = (f"closest {lab(b_)}-{lab(a_)} {words(dd[a_, b_])}" if not low else
            f"{len(low)} pair(s) under the limit: " + ", ".join(f"{lab(q)}-{lab(p)} {words(dd[p, q])}" for p, q in low[:6]))
    if blobs:
        note += f"; {blobs} ink blob(s) hold 2+ dots (merged)"
    results.append(("gap: min edge gap px", dd[a_, b_], OUTLINE_MIN_GAP_PX, dd[a_, b_] >= OUTLINE_MIN_GAP_PX, note))
    for p, q in low:                                   # p > q; a neighbour pair is drawn as path pair q (or p)
        p, q = int(p), int(q)
        bad_pairs.append(q if q + 1 == p else p if (p + 1) % n == q else (q, p))
    cid, regular = size_clusters(2 * r)
    gcv = gap.std() / gap.mean() if gap.mean() > 0 else float("nan")
    k = int(np.argmax(np.abs(gap - np.median(gap))))
    results.append(("gap: CV of neighbour gaps", gcv, float("nan"), True,
                    f"INFO (corner chords and the settled / corner dots differ by design); {gap.min():.1f}-"
                    f"{gap.max():.1f} px, median {np.median(gap):.1f}; furthest from it {lab(k)}-{lab(k + 1)} {gap[k]:.1f} px"))
    worst_pairs.append(k)

    # size rhythm
    d = 2 * r
    reg = float(np.median(d[cid == regular]))
    med = np.array([np.median(d[cid == c]) for c in range(cid.max() + 1)])
    off = d / med[cid] - 1
    outl = np.nonzero(np.abs(off) > OUTLINE_SIZE_TOL)[0]
    settled = np.nonzero(d >= OUTLINE_SETTLED_MIN * reg)[0]
    names = []
    for c in range(cid.max() + 1):
        nm = "regular" if c == regular else "settled" if (np.isin(np.nonzero(cid == c)[0], settled).all()
                                                           and c > regular) else "small" if c < regular else "large"
        names.append(nm)
    desc = ", ".join(f"{names[c]} {med[c]:.1f} px ({med[c] / reg:.2f}x) x{int((cid == c).sum())}" for c in range(len(med)))
    results.append(("size: outliers > 5% off their cluster", len(outl), 0, not len(outl),
                    f"clusters {desc}" + (f"; " + ", ".join(f"{lab(k)} {off[k]:+.0%}" for k in outl[:6]) if len(outl) else "")))
    results.append(("size: settled dots", len(settled), 1, len(settled) == 1,
                    f">= {OUTLINE_SETTLED_MIN}x regular; " + (", ".join(f"{lab(k)} {d[k] / reg:.2f}x" for k in settled)
                                                             if len(settled) else "none")))

    # symmetry about the vertical axis through the fitted card's centre (one misplaced dot doesn't move it)
    ax_ = card[0]
    mir = np.column_stack([2 * ax_ - xy[:, 0], xy[:, 1]])
    dist, m = cKDTree(xy).query(mir)
    err = np.maximum(dist, np.abs(r - r[m]))
    k = int(np.argmax(err))
    results.append(("symmetry: mirror error px", err[k], OUTLINE_SYMMETRY_PX, err[k] <= OUTLINE_SYMMETRY_PX,
                    f"axis x {ax_:.1f} (tile centre {TILE / 2:.0f}); worst {lab(k)} vs {lab(m[k])}: position "
                    f"{dist[k]:.1f} px, radius {abs(r[k] - r[m[k]]):.1f} px"))

    # optical centre (as in the halftone mode: midpoint of the bbox centre and the ink centroid)
    w = ink.sum()
    yy, xx = np.mgrid[:TILE, :TILE]
    cx, cy = (ink * xx).sum() / w, (ink * yy).sum() / w
    bx, by = ((xy - r[:, None]).min(axis=0) + (xy + r[:, None]).max(axis=0)) / 2
    oc = max(abs((cx + bx) / 2 - TILE / 2), abs((cy + by) / 2 - TILE / 2)) / TILE
    results.append(("optical centre offset / tile", oc, CENTROID_TOL, oc <= CENTROID_TOL,
                    f"centroid ({cx:.0f}, {cy:.0f}), bbox centre ({bx:.0f}, {by:.0f})"))

    # small sizes: what the eye integrates at 58 / 29 px (area downsample + PERCEIVED_BLUR, as in check 2)
    work = Image.fromarray((np.clip(ink, 0, 1) * 255).astype(np.uint8)).convert("RGB")
    previews, small_info = {}, {}
    t = np.linspace(0, 1, 65)
    gy, gx = np.mgrid[-1:1.01:0.1, -1:1.01:0.1]
    disc = np.column_stack([gx.ravel(), gy.ravel()])[np.hypot(gx, gy).ravel() <= 1] * pitch / 2
    for size in (58, 29):
        previews[size] = img.resize((size, size), Image.BOX)
        small = np.asarray(work.resize((size, size), Image.BOX), dtype=float)[:, :, 0] / 255
        small = ndimage.gaussian_filter(small, PERCEIVED_BLUR)
        kk = TILE / size
        at = lambda p: ndimage.map_coordinates(small, [p[..., 1].ravel() / kk - 0.5, p[..., 0].ravel() / kk - 0.5],
                                               order=1, mode="nearest").reshape(p.shape[:-1])
        peak = at(xy)
        seg = at(xy[:, None] + (xy[nxt] - xy)[:, None] * t[None, :, None])
        valley = seg.min(axis=1)
        sep = valley < OUTLINE_VALLEY * np.minimum(peak, peak[nxt])
        mass = at(xy[:, None] + disc[None]).mean(axis=1)
        small_info[size] = (peak, sep)
        j = int(np.argmin(peak))
        results.append((f"small: min peak ink at {size:>2} px", peak[j], OUTLINE_PEAK_MIN[size],
                        peak[j] >= OUTLINE_PEAK_MIN[size],
                        f"faintest {lab(j)}, median {np.median(peak):.2f}" + ("; the outline vanishes below the limit" if size == 29 else "")))
        share = sep.mean()
        lim = OUTLINE_SEPARATED_MIN[size]
        cont = ", ".join(f"{lab(q)}-{lab(q + 1)}" for q in np.nonzero(~sep)[0][:6])
        results.append((f"small: separated pairs at {size:>2} px", share, lim if lim else float("nan"),
                        lim is None or share >= lim,
                        ("INFO (a continuous line is acceptable at 29 px); " if lim is None else "")
                        + f"{int(sep.sum())} of {n}: ink between the centres dips below {OUTLINE_VALLEY} x the fainter peak"
                        + (f"; blurred: {cont}" if cont else "")))
        if len(settled) == 1:
            s = int(settled[0])
            regm = cid == regular
            ratio = mass[s] / np.median(mass[regm])
            results.append((f"small: settled reads bigger at {size:>2} px", ratio, OUTLINE_SETTLED_SMALL,
                            ratio >= OUTLINE_SETTLED_SMALL,
                            f"{lab(s)}: perceived ink over a disc of half a pitch / regular median; peak "
                            f"{peak[s]:.2f} vs {np.median(peak[regm]):.2f}"))
        else:
            results.append(na(f"small: settled reads bigger at {size:>2} px", OUTLINE_SETTLED_SMALL,
                              f"{len(settled)} settled dots"))

    name = Path(path).name
    fails = sum(not x[3] for x in results)
    out = Path(out) if out else default_out(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    home_img = home_mock(img, out.with_name(f"{Path(path).stem}-home.png")) if home else None
    outline_sheet(img, dots, spacing, cid, names, bad_pairs, worst_pairs, small_info, previews, results, out, home_img)
    if quiet:
        return fails, results
    print(f"design-review {name}: mode outline, {n} dots ({'SVG circles' if fromsvg else 'PNG distance-transform peaks'}), "
          f"mean pitch {pitch:.1f} px; dots numbered along the path, clockwise from {lab(0)}"
          f"{' (the settled dot)' if len(settled) == 1 and settled[0] == 0 else ''}")
    print(f"{'METRIC':<40}{'VALUE':>8}{'LIMIT':>8}  RESULT")
    for m_, v, lim, ok, note in results:
        cmp = "==" if m_.startswith(OUTLINE_EXACT) else ">=" if higher_is_better(m_) else "<="
        lims = "-" if lim != lim else f"{lim:.3g}"
        print(f"{m_:<40}{fmt(v)}{cmp:>4}{lims:<5} {'N/A ' if v != v else 'PASS' if ok else 'FAIL'}  {note}")
    print(f"RESULT: {'FAIL' if fails else 'PASS'} ({fails} of {len(results)} metrics failed)")
    print(f"sheet: {out}" + (f"\nhome:  {out.with_name(Path(path).stem + '-home.png')}" if home else ""))
    return fails, results


def outline_sheet(img, dots, spacing, cid, names, bad_pairs, worst_pairs, small_info, previews, results, out, home_img):
    """The render with dots numbered along the path and ringed by size cluster, pairs under the min gap in red (a
    dashed line when they are not path neighbours), spacing failures and the worst pairs in orange; spacing / gap per pair; 58 / 29 px
    previews with the dots blurred into their neighbour ringed; the results."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    n = len(dots)
    colors = {"regular": "tab:blue", "small": "tab:green", "settled": "tab:purple", "large": "tab:red"}
    rows = 2 + (home_img is not None)
    fig = plt.figure(figsize=(14, 13 + (5 if home_img is not None else 0)))
    gs = fig.add_gridspec(rows, 4, height_ratios=[3, 1] + ([1.6] if home_img is not None else []))
    ax = fig.add_subplot(gs[0, :3])
    ax.imshow(img, extent=(0, TILE, TILE, 0))
    for k, (x, y, r) in enumerate(dots):
        c = colors[names[cid[k]]]
        ax.add_patch(matplotlib.patches.Circle((x, y), r + 3, fill=False, color=c, lw=1.5))
        ax.text(x, y, str(k + 1), color="white", fontsize=8, ha="center", va="center", weight="bold",
                bbox=dict(boxstyle="round,pad=0.15", fc=c, ec="none", alpha=0.85))
    for p in worst_pairs:
        a, b = dots[p, :2], dots[(p + 1) % n, :2]
        ax.plot([a[0], b[0]], [a[1], b[1]], color="orange", lw=3, alpha=0.8)
    for p in bad_pairs:
        i, j = (p, (p + 1) % n) if isinstance(p, int) else p
        ax.plot([dots[i, 0], dots[j, 0]], [dots[i, 1], dots[j, 1]], color="red", lw=3,
                ls="-" if isinstance(p, int) else "--")
    ax.set_xlim(0, TILE); ax.set_ylim(TILE, 0)
    ax.set_title("dots numbered along the path; ring = size cluster (" + ", ".join(
        f"{nm} {colors[nm].split(':')[1]}" for nm in dict.fromkeys(names)) + ")\nred = pair under the min gap "
        "(dashed: not path neighbours), orange = spacing off the limit or the worst spacing / gap pair", fontsize=9)
    pv = gs[0, 3].subgridspec(2, 1)
    for k, size in enumerate((58, 29)):
        a = fig.add_subplot(pv[k])
        a.imshow(previews[size].resize((232, 232), Image.NEAREST), extent=(0, TILE, TILE, 0))
        peak, sep = small_info[size]
        for q in np.nonzero(~sep)[0]:                  # pairs blurred into a line at this size
            i, j = q, (q + 1) % n
            a.plot([dots[i, 0], dots[j, 0]], [dots[i, 1], dots[j, 1]], color="orange", lw=1.5, alpha=0.7)
        a.set_title(f"{size} px, enlarged ({int(sep.sum())}/{n} pairs separated; orange = blurred)", fontsize=8)
        a.axis("off")
    a = fig.add_subplot(gs[1, :3])
    xy, r = dots[:, :2], dots[:, 2]
    nxt = (np.arange(n) + 1) % n
    idx = np.arange(1, n + 1)
    a.bar(idx - 0.2, spacing / spacing.mean(), 0.4, color="0.5", label="spacing / mean")
    a2 = a.twinx()
    a2.bar(idx + 0.2, np.hypot(*(xy[nxt] - xy).T) - r - r[nxt], 0.4, color="tab:blue", label="edge gap px")
    a2.axhline(OUTLINE_MIN_GAP_PX, color="red", lw=0.8, ls="--")
    a.axhline(1 + OUTLINE_SPACING_DEV, color="0.3", lw=0.8, ls=":"); a.axhline(1 - OUTLINE_SPACING_DEV, color="0.3", lw=0.8, ls=":")
    a.set_ylim(0, max(1.5, (spacing / spacing.mean()).max() * 1.05)); a.set_xticks(idx)
    a.set_xticklabels([f"{k}-{k % n + 1}" for k in idx], fontsize=6, rotation=90)
    a.set_title("per pair along the path: arc spacing / mean (grey, dotted = limit), edge gap px (blue, red dashed = min)",
                fontsize=9, loc="left")
    txt = fig.add_subplot(gs[1, 3]); txt.axis("off")
    txt.text(0, 1, "\n".join(f"{'N/A ' if v != v else 'PASS' if ok else 'FAIL'} {m}: {v:.3f}" for m, v, _, ok, _ in results),
             fontsize=6.5, va="top", family="monospace")
    if home_img is not None:
        a = fig.add_subplot(gs[2, :]); a.imshow(home_img); a.axis("off")
    fig.tight_layout(); fig.savefig(out, dpi=90); plt.close(fig)


# ---------------------------------------------------------------- flat mode
def medial_points(mask):
    """Medial-axis points of a binary mask (the ink, or the paper): dict of arrays x, y (the pixel), w (width: the mask
    pixels between the two nearest boundary pixels across), cx, cy (the midpoint of those two boundary pixels) and
    ux, uy (unit vector across). A pixel is on the axis when it and a neighbour have their nearest boundary pixels
    >= 120 degrees apart seen from the pair (FLAT_OPPOSITE_COS); of its neighbours, the widest such pair is kept."""
    _, (fy, fx) = ndimage.distance_transform_edt(mask, return_indices=True)
    h, w = mask.shape
    yy, xx = np.mgrid[:h, :w]
    best, oy, ox = np.zeros(mask.shape), np.zeros(mask.shape), np.zeros(mask.shape)
    for dy, dx in ((0, 1), (1, 0), (1, 1), (1, -1)):
        a = (slice(0, h - dy), slice(max(0, -dx), w - max(0, dx)))
        b = (slice(dy, h), slice(max(0, dx), w - max(0, -dx)))
        my, mx = (yy[a] + yy[b]) / 2, (xx[a] + xx[b]) / 2
        v1, v2 = np.stack([fy[a] - my, fx[a] - mx]), np.stack([fy[b] - my, fx[b] - mx])
        cos = (v1 * v2).sum(0) / np.maximum(np.hypot(*v1) * np.hypot(*v2), 1e-9)
        s = np.hypot(fy[a] - fy[b], fx[a] - fx[b])
        ok = mask[a] & mask[b] & (cos <= FLAT_OPPOSITE_COS)
        for p, q in ((a, b), (b, a)):
            upd = ok & (s > best[p])
            best[p] = np.where(upd, s, best[p])
            oy[p], ox[p] = np.where(upd, fy[q], oy[p]), np.where(upd, fx[q], ox[p])
    ys, xs = np.nonzero(best > 0)
    y1, x1, y2, x2, s = fy[ys, xs], fx[ys, xs], oy[ys, xs], ox[ys, xs], best[ys, xs]
    return dict(x=xs, y=ys, w=s - 1, cx=(x1 + x2) / 2, cy=(y1 + y2) / 2, ux=(x2 - x1) / s, uy=(y2 - y1) / s)


def axis_runs(m, sel):
    """Connected runs (points within ~2 px) of the selected axis points: index arrays, the longest first."""
    if not sel.any():
        return []
    grid = np.zeros((TILE, TILE), bool)
    grid[m["y"][sel], m["x"][sel]] = True
    lab, _ = ndimage.label(ndimage.binary_dilation(grid, iterations=2), structure=np.ones((3, 3)))
    gid = np.where(sel, lab[m["y"], m["x"]], 0)
    o = np.argsort(gid, kind="stable")
    runs = np.split(o, np.nonzero(np.diff(gid[o]))[0] + 1)
    return sorted((r for r in runs if gid[r[0]]), key=lambda r: -run_length(m, r))


def run_length(m, r):
    return math.hypot(np.ptp(m["x"][r]), np.ptp(m["y"][r]))


def is_tip(m, r):
    """A sharp tip: the run narrows to <= FLAT_TIP_PX, at least doubles in width, and either its narrowest point sits
    at one end (>= 70% of the run's length from its farthest point: a spike, a sliver running into a tangent) or it
    opens like a wedge both ways (90% of its points >= FLAT_TIP_OPEN x their distance wider: two corners meeting where
    XOR edges cross at a shallow angle). A hairline seam or a strip of even width is not a tip."""
    w, x, y = m["w"][r], m["x"][r], m["y"][r]
    j = int(np.argmin(w))
    d = np.hypot(x - x[j], y - y[j])
    return (w[j] <= FLAT_TIP_PX and w.max() >= 2 * max(w[j], 1)
            and (d.max() >= 0.7 * run_length(m, r) or (w >= w[j] + FLAT_TIP_OPEN * d - 1).mean() >= 0.9))


def run_text(m, r, kind):
    j = r[np.argmin(m["w"][r])]
    return f"{kind} {m['w'][r].min():.0f}-{m['w'][r].max():.0f} px wide over {run_length(m, r):.0f} px at x {m['x'][j]}, y {m['y'][j]}"


def cross_contrast(small, size, m, stroke):
    """Per axis point at icon size: how far a stroke's perceived ink stands above both flanks (1 icon px past its
    edges, across it), or how far both flanks stand above a gap's."""
    k = TILE / size
    at = lambda y, x: ndimage.map_coordinates(small, [y / k - 0.5, x / k - 0.5], order=1, mode="nearest")
    off = m["w"] / 2 + k
    c = at(m["cy"], m["cx"])
    f1 = at(m["cy"] - m["uy"] * off, m["cx"] - m["ux"] * off)
    f2 = at(m["cy"] + m["uy"] * off, m["cx"] + m["ux"] * off)
    return c - np.maximum(f1, f2) if stroke else np.minimum(f1, f2) - c


def review_flat(path, out=None, home=False, quiet=False):
    """Flat mode: a solid flat mark (one even-odd path). Prints the report and writes the sheet; returns (fails, results)."""
    img, rgb, _ = load(path, "x")
    ink, bg, inkc = ink_map(rgb)
    solid = ink > 0.5
    if solid.sum() < 100:
        return nothing_measured(path, quiet, f"{int(solid.sum())} ink px")
    ys_, xs_ = np.nonzero(solid)
    x0, x1, y0, y1 = xs_.min(), xs_.max(), ys_.min(), ys_.max()
    paper = medial_points(~solid)
    inb = (paper["x"] >= x0) & (paper["x"] <= x1) & (paper["y"] >= y0) & (paper["y"] <= y1)
    feats = {"stroke": medial_points(solid), "gap": {k: v[inb] for k, v in paper.items()}}
    results, marks = [], {}

    # at 1024: thinnest stroke / gap, sharp tips (is_tip: runs under the floor narrowing to a point) set aside
    tip, necks = {}, {}
    for kind, m in feats.items():
        tip[kind] = np.zeros(len(m["w"]), bool)
        runs = axis_runs(m, m["w"] < FLAT_MIN_PX)
        tips = [r for r in runs if is_tip(m, r)]
        for r in tips + [r for r in runs if run_length(m, r) < FLAT_CORNER_PX]:
            tip[kind][r] = True
        # the thinnest neck or strip: a point no narrower than its neighbours (within its own width, tips included),
        # so the root of a tip, where the tip was cut off at FLAT_MIN_PX, is not reported as a stroke
        tree = cKDTree(np.column_stack([m["x"], m["y"]]))
        rest = [q for q in np.nonzero(~tip[kind])[0] if m["w"][q] <= 1 + min(
            m["w"][n_] for n_ in tree.query_ball_point((m["x"][q], m["y"][q]), min(max(m["w"][q], 4), 2 * FLAT_MIN_PX)))]
        necks[kind] = np.array(rest, int)
        if not rest:
            results.append(na(f"{kind}: thinnest px", FLAT_MIN_PX, f"no {kind} neck or strip outside sharp tips"))
            continue
        j = rest[int(np.argmin(m["w"][rest]))]
        v = float(m["w"][j])
        marks[kind] = (m["cx"][j], m["cy"][j], m["ux"][j], m["uy"][j], v)
        results.append((f"{kind}: thinnest px", v, FLAT_MIN_PX, v >= FLAT_MIN_PX,
                        f"at x {m['x'][j]}, y {m['y'][j]} (= {v * 58 / TILE:.2f} px at 58, {v * 29 / TILE:.2f} px at 29); "
                        f"{len(tips)} sharp tip(s) set aside" + (" (counters and cut-outs inside the bbox)" if kind == "gap" else "")))

    # optical centre and margins, as in the halftone mode
    w = ink.sum()
    yy, xx = np.mgrid[:TILE, :TILE]
    cx, cy = (ink * xx).sum() / w, (ink * yy).sum() / w
    bx, by = (x0 + x1 + 1) / 2, (y0 + y1 + 1) / 2
    oc = max(abs((cx + bx) / 2 - TILE / 2), abs((cy + by) / 2 - TILE / 2)) / TILE
    results.append(("optical centre offset / tile", oc, CENTROID_TOL, oc <= CENTROID_TOL,
                    f"centroid ({cx:.0f}, {cy:.0f}), bbox centre ({bx:.0f}, {by:.0f})"))
    ml, mr, mt, mb = x0, TILE - 1 - x1, y0, TILE - 1 - y1
    for nm, a_, b_ in (("left/right", ml, mr), ("top/bottom", mt, mb)):
        imb = abs(a_ - b_) / TILE
        results.append((f"bbox margin imbalance {nm} / tile", imb, BBOX_IMBALANCE, imb <= BBOX_IMBALANCE,
                        f"margins {a_} vs {b_} px"))

    # at 58 / 29 px: what the eye integrates (area downsample + PERCEIVED_BLUR, as in check 2); every axis point under
    # FLAT_TEST_MAX icon px is tested across: strokes that fade, gaps that close, tips that are lost
    work = Image.fromarray((np.clip(ink, 0, 1) * 255).astype(np.uint8))
    previews, lost, survivors = {}, {}, {}
    for size in (58, 29):
        k = TILE / size
        previews[size] = img.resize((size, size), Image.BOX)
        small = ndimage.gaussian_filter(np.asarray(work.resize((size, size), Image.BOX), dtype=float) / 255, PERCEIVED_BLUR)
        lost[size], tips_lost = [], []
        for kind, m in feats.items():
            fail = (m["w"] < FLAT_TEST_MAX * k) & (cross_contrast(small, size, m, kind == "stroke") < FLAT_CONTRAST)
            survivors[size, kind] = necks[kind][~fail[necks[kind]]]
            for r in axis_runs(m, fail):
                if run_length(m, r) < FLAT_CORNER_PX:
                    continue
                if is_tip(m, r) or tip[kind][r[np.argmin(m["w"][r])]]:   # narrows into a tip, corner or crossing
                    tips_lost.append((run_length(m, r), kind, r))
                elif run_length(m, r) >= FLAT_VANISH_LEN * k:
                    lost[size].append((kind, m, r))
        for kind, word in (("stroke", "faded strokes"), ("gap", "closed gaps")):
            runs = [r for kd, _, r in lost[size] if kd == kind]
            results.append((f"small: {word} at {size:>2} px", len(runs), 0, not runs,
                            "; ".join(run_text(feats[kind], r, kind) for r in runs[:5]) if runs else
                            f"none (contrast across >= {FLAT_CONTRAST} wherever under {FLAT_TEST_MAX:g} icon px)"))
        if tips_lost:
            ln, kind, r = max(tips_lost, key=lambda t: t[0])
            results.append((f"small: longest tip lost at {size:>2} px", ln, FLAT_TIP_LOSS[size], ln <= FLAT_TIP_LOSS[size],
                            f"px at 1024 (= {ln / k:.1f} icon px); worst {run_text(feats[kind], r, kind + ' tip')}; "
                            f"{len(tips_lost)} tip(s) blunted"))
            lost[size] += [(kind, feats[kind], r) for ln_, kind, r in tips_lost if ln_ > FLAT_TIP_LOSS[size]]
        else:
            results.append((f"small: longest tip lost at {size:>2} px", 0.0, FLAT_TIP_LOSS[size], True, "no sharp tip lost"))
    sv = [(float(feats[kd]["w"][survivors[29, kd]].min()), kd) for kd in feats if len(survivors[29, kd])]
    if sv:
        v, kd = min(sv)
        results.append(("small: smallest surviving at 29 px", v, float("nan"), True,
                        f"INFO: the thinnest {kd} neck or strip (px at 1024) still separated at 29 px (= {v * 29 / TILE:.2f} icon px)"))

    name = Path(path).name
    fails = sum(not x[3] for x in results)
    out = Path(out) if out else default_out(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    home_img = home_mock(img, out.with_name(f"{Path(path).stem}-home.png")) if home else None
    flat_sheet(img, feats, tip, marks, lost, previews, results, out, home_img)
    if quiet:
        return fails, results
    print(f"design-review {name}: mode flat, ink bbox x {x0}-{x1}, y {y0}-{y1}; medial axis: "
          f"{len(feats['stroke']['w'])} ink px, {len(feats['gap']['w'])} paper px inside the bbox")
    print(f"{'METRIC':<40}{'VALUE':>8}{'LIMIT':>8}  RESULT")
    for m_, v, lim, ok, note in results:
        cmp = "==" if m_.startswith(FLAT_EXACT) else ">=" if higher_is_better(m_) else "<="
        lims = "-" if lim != lim else f"{lim:.3g}"
        print(f"{m_:<40}{fmt(v)}{cmp:>4}{lims:<5} {'N/A ' if v != v else 'PASS' if ok else 'FAIL'}  {note}")
    print(f"RESULT: {'FAIL' if fails else 'PASS'} ({fails} of {len(results)} metrics failed)")
    print(f"sheet: {out}" + (f"\nhome:  {out.with_name(Path(path).stem + '-home.png')}" if home else ""))
    return fails, results


def flat_sheet(img, feats, tip, marks, lost, previews, results, out, home_img):
    """The render with the medial axis (grey; sharp tips orange), the thinnest stroke (red) and gap (blue) cross-section,
    and what is lost at 29 px (red: strokes that fade, blue: gaps that close, thick); 58 / 29 px previews with what is
    lost at that size; the results."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    colors = {"stroke": "red", "gap": "tab:blue"}
    fig = plt.figure(figsize=(14, 11 + (5 if home_img is not None else 0)))
    gs = fig.add_gridspec(2 + (home_img is not None), 4, height_ratios=[3, 1] + ([1.6] if home_img is not None else []))
    ax = fig.add_subplot(gs[0, :3])
    ax.imshow(img, extent=(0, TILE, TILE, 0))
    for kind, m in feats.items():
        ax.scatter(m["x"][~tip[kind]], m["y"][~tip[kind]], s=0.2, c="0.6")
        ax.scatter(m["x"][tip[kind]], m["y"][tip[kind]], s=0.6, c="orange")
    for kind, m, r in lost[29]:
        ax.scatter(m["x"][r], m["y"][r], s=4, c=colors[kind])
    for kind, (x, y, ux, uy, v) in marks.items():         # the cross-section, ringed
        ax.plot([x - ux * v / 2, x + ux * v / 2], [y - uy * v / 2, y + uy * v / 2], color=colors[kind], lw=2.5)
        ax.add_patch(matplotlib.patches.Circle((x, y), max(v / 2, 10) + 8, fill=False, color=colors[kind], lw=1.5))
        ax.text(x + max(v / 2, 10) + 12, y, f"thinnest {kind} {v:.0f} px", color=colors[kind], fontsize=9, va="center",
                weight="bold", bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.8))
    ax.set_xlim(0, TILE); ax.set_ylim(TILE, 0)
    ax.set_title("medial axis (grey; sharp tips, corners, crossings orange); ringed line = thinnest stroke (red) / gap (blue)\n"
                 "lost at 29 px: red = stroke fades, blue = gap closes, tips beyond the limit", fontsize=9)
    pv = gs[0, 3].subgridspec(2, 1)
    for k, size in enumerate((58, 29)):
        a = fig.add_subplot(pv[k])
        a.imshow(previews[size].resize((232, 232), Image.NEAREST), extent=(0, TILE, TILE, 0))
        for kind, m, r in lost[size]:
            a.scatter(m["x"][r], m["y"][r], s=1.5, c=colors[kind], alpha=0.6)
        a.set_title(f"{size} px, enlarged ({len(lost[size])} lost)", fontsize=8)
        a.axis("off")
    txt = fig.add_subplot(gs[1, :]); txt.axis("off")
    txt.text(0, 1, "\n".join(f"{'N/A ' if v != v else 'PASS' if ok else 'FAIL'} {m}: {v:.3f}  {note[:150]}"
                             for m, v, _, ok, note in results), fontsize=7, va="top", family="monospace")
    if home_img is not None:
        a = fig.add_subplot(gs[2, :]); a.imshow(home_img); a.axis("off")
    fig.tight_layout(); fig.savefig(out, dpi=90); plt.close(fig)


# ---------------------------------------------------------------- sheet
def sheet(img, curves, bands, ramp, rows_px, bad_x, bad_pts, flip, axis, previews, results, out, home_img):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    shown = img.transpose(Image.Transpose.TRANSPOSE) if axis == "y" else img
    shown = shown.transpose(Image.Transpose.FLIP_LEFT_RIGHT) if flip else shown
    rows = 6 + (2 if home_img is not None else 0)
    fig = plt.figure(figsize=(14, 3 * rows))
    gs = fig.add_gridspec(rows, 4, height_ratios=[3, 1, 1, 1, 1, 1] + ([3, 3] if home_img is not None else []))
    ax = fig.add_subplot(gs[0, :3])
    ax.imshow(shown, extent=(0, TILE, TILE, 0))
    for x in bad_x:
        ax.axvspan(x - 4, x + 4, color="red", alpha=0.25)
    for x, y in bad_pts:                               # failing marks (touching / merged)
        ax.add_patch(matplotlib.patches.Circle((x, y), 9, fill=False, color="red", lw=1.2))
    ax.axvline(ramp[0], color="tab:blue", lw=0.8); ax.axvline(ramp[1], color="tab:blue", lw=0.8)
    for y in rows_px:
        ax.axhline(y, color="tab:blue", lw=0.5, ls=":")
    ax.set_title(f"{'flipped so ink rises left to right, ' if flip else ''}{'axis y shown as x, ' if axis == 'y' else ''}"
                 "red = failing spot (circle = failing mark), blue = ramp and profiled rows", fontsize=9)
    pv = gs[0, 3].subgridspec(2, 1)
    for k, size in enumerate((58, 29)):
        a = fig.add_subplot(pv[k])
        a.imshow(previews[size].resize((232, 232), Image.NEAREST)); a.set_title(f"{size} px, enlarged", fontsize=8)
        a.axis("off")
    plots = [("coverage (black 1024 blurred, grey raw 8 px, blue 58, orange 29)", None),
             ("|step| / limit", 0), ("drawdown / limit", 1), ("|2nd diff| / limit", 2)]
    colors = {1024: "black", 58: "tab:blue", 29: "tab:orange"}
    for r, (title, m) in enumerate(plots, start=1):
        a = fig.add_subplot(gs[r, :3]); a.set_xlim(0, TILE); a.set_title(title, fontsize=9, loc="left")
        for size, (xs, p, raw, (i0, i1, steps, draw, d2)) in curves.items():
            if m is None:
                a.plot(xs, p, color=colors[size], lw=1.2)
                if raw is not None:
                    a.plot(xs, raw, color="0.7", lw=0.8)
            else:
                arr = (steps, draw, d2)[m] / PROFILE_LIMITS[size][m]
                off = (0.5, 0, 1)[m]
                a.plot(np.interp(np.arange(len(arr)) + i0 + off, np.arange(len(xs)), xs), arr, color=colors[size], lw=1.2)
        if m is not None:
            a.axhline(1, color="red", lw=0.8, ls="--")
        for x in bad_x:
            a.axvspan(x - 4, x + 4, color="red", alpha=0.15)
        a.axvline(ramp[0], color="tab:blue", lw=0.5); a.axvline(ramp[1], color="tab:blue", lw=0.5)
    a = fig.add_subplot(gs[5, :3]); a.set_xlim(0, TILE)
    a.set_title(f"order per {ORDER_BAND_PX} px band of marks: |psi6| (green), 1-CV(NN) (purple); mark radius / max "
                "(grey); hole fraction (orange)",
                fontsize=9, loc="left")
    if len(bands):
        a.plot(bands[:, 0], bands[:, 1], "o-", color="tab:green"); a.plot(bands[:, 0], bands[:, 2], "o-", color="tab:purple")
        a.plot(bands[:, 0], bands[:, 3] / bands[:, 3].max(), "o-", color="0.6")
        a.plot(bands[:, 0], bands[:, 6], "o-", color="tab:orange")
    a.set_ylim(0, 1.05)
    txt = fig.add_subplot(gs[1:6, 3]); txt.axis("off")
    txt.text(0, 1, "\n".join(f"{'N/A ' if v != v else 'PASS' if ok else 'FAIL'} {m}: {v:.3f}" for m, v, _, ok, _ in results),
             fontsize=7, va="top", family="monospace")
    if home_img is not None:
        a = fig.add_subplot(gs[6:, :]); a.imshow(home_img); a.axis("off")
    fig.tight_layout(); fig.savefig(out, dpi=90); plt.close(fig)


# ---------------------------------------------------------------- home screen mock
def fetch_icons():
    """Apple's own app icons via the public iTunes lookup API, cached in a gitignored folder."""
    ICON_CACHE.mkdir(parents=True, exist_ok=True)
    meta = ICON_CACHE / "icons.json"
    if not meta.exists():
        try:
            url = "https://itunes.apple.com/lookup?country=us&id=" + ",".join(map(str, ICON_IDS))
            with urllib.request.urlopen(url, timeout=10) as r:
                res = json.load(r)["results"]
            for app in res:
                urllib.request.urlretrieve(app["artworkUrl512"], ICON_CACHE / f"{app['trackId']}.jpg")
            meta.write_text(json.dumps({str(a["trackId"]): a["trackName"].replace("Apple ", "") for a in res}))
        except Exception as e:
            print(f"home: icon fetch failed ({e}); using neutral stand-ins", file=sys.stderr)
            return [(None, "App")] * len(ICON_IDS)
    names = json.loads(meta.read_text())
    return [(Image.open(ICON_CACHE / f"{i}.jpg").convert("RGB"), names.get(str(i), "App")) for i in ICON_IDS]


def squircle_mask(size, scale=4):
    """iOS continuous-corner icon shape, approximated by a superellipse |x|^5 + |y|^5 = 1."""
    n = size * scale
    t = (np.arange(n) + 0.5) / n * 2 - 1
    m = (np.abs(t)[None, :] ** 5 + np.abs(t)[:, None] ** 5) <= 1
    return Image.fromarray((m * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)


def home_mock(render, out):
    """Two wallpapers (dark, light), 4-column grid at @3x of a 402 pt wide iPhone: 60 pt icons = 180 px,
    labels 12 pt; the render sits in the first row, third column."""
    icon, w = 180, 1206
    gap = (w - 4 * icon) // 5
    mask = squircle_mask(icon)
    icons = fetch_icons()
    font_path = "/System/Library/Fonts/SFNS.ttf"
    font = ImageFont.truetype(font_path, 34) if os.path.exists(font_path) else ImageFont.load_default(34)
    panels = []
    for top, bottom, label in (((28, 30, 44), (10, 10, 14), (255, 255, 255)), ((214, 222, 232), (238, 240, 236), (20, 20, 20))):
        h = 2 * (icon + 90) + 60
        g = np.linspace(0, 1, h)[:, None, None]
        bgarr = (np.array(top) * (1 - g) + np.array(bottom) * g) * np.ones((h, w, 3))
        panel = Image.fromarray(bgarr.astype(np.uint8))
        draw = ImageDraw.Draw(panel)
        apps = [icons[0], icons[1], (render, "La Carte"), icons[2], icons[3], icons[4], icons[5], (None, "App")]
        for k, (im, name) in enumerate(apps):
            x, y = gap + (k % 4) * (icon + gap), 40 + (k // 4) * (icon + 90)
            tile = im.resize((icon, icon), Image.LANCZOS) if im is not None else Image.new("RGB", (icon, icon), (142, 142, 147))
            panel.paste(tile, (x, y), mask)
            draw.text((x + icon / 2, y + icon + 12), name, fill=label, font=font, anchor="ma")
        panels.append(panel)
    sheet = Image.new("RGB", (w * 2 + 40, panels[0].height), (255, 255, 255))
    sheet.paste(panels[0], (0, 0)); sheet.paste(panels[1], (w + 40, 0))
    sheet.save(out)
    return sheet


# ---------------------------------------------------------------- synthetic reference ramp
def synthetic_ramp(out, seed=7):
    """A smooth noise -> structure -> solid card (round 6 silhouette): the reference that must PASS.
    1. Hex lattice (pitch A) over the ramp, and Bridson Poisson-disc points of about the same density.
    2. Match them one-to-one (linear_sum_assignment); each dot sits at lerp(random, lattice, w(x)), w easing
       out until c = SYN_ON_SITE: order rises continuously while density stays put.
    3. One coverage c(x) = smoothstep from 0.04 to 1 (zero slope into the solid). Each lattice cell holds one
       ink mark of area c * cell: a round dot below C1 = 0.35, then a rounded hexagon (a hexagon of apothem k
       Minkowski-summed with a disc of radius rho) whose extent k + rho grows to A/2 while rho shrinks to 0,
       so the marks become the lattice's own cells and close into solid. No dots -> holes flip, so no seam
       (a flip in one column is a seam: it fails `seam: polarity mix`)."""
    rng = np.random.default_rng(seed)
    S = 4                                          # supersampling
    BG, INK = np.array([249, 250, 245]), np.array([28, 28, 28])
    W, H, R, CX, CY = 620, 400, 64, 490, 512
    XL = CX - W / 2
    XS = XL + 0.72 * W                             # solid from here (c = 1)
    A = 12.0                                       # lattice pitch
    SYN_ON_SITE = 0.55                             # dots reach their lattice site at this coverage
    sstep = lambda t: (lambda u: u * u * (3 - 2 * u))(np.clip(t, 0, 1))
    c = lambda x: 0.04 + 0.96 * sstep((x - XL) / (XS - XL))
    gx = np.linspace(XL, XS, 4000)
    xh = gx[np.argmax(c(gx) >= SYN_ON_SITE)]
    w = lambda x: 1 - (1 - np.clip((x - XL) / (xh - XL), 0, 1)) ** 2    # ease out: |psi6| rises evenly

    dx = A * math.sqrt(3) / 2                      # hex lattice in vertical columns
    lat = np.array([(x, y) for i, x in enumerate(np.arange(XS, XL - 2 * A, -dx))
                    for y in np.arange(CY - H / 2 - A + (A / 2) * (i % 2), CY + H / 2 + A, A)])
    box = (XL - A, xh + A, CY - H / 2 - A, CY + H / 2 + A)      # Bridson Poisson-disc in the dot zone
    rmin = 0.8 * A
    cell = rmin / math.sqrt(2)
    pts, active, grid = [], [], {}
    def add(p):
        pts.append(p); active.append(p); grid[(int(p[0] // cell), int(p[1] // cell))] = p
    add((rng.uniform(box[0], box[1]), rng.uniform(box[2], box[3])))
    while active:
        k = rng.integers(len(active)); base = active[k]
        for _ in range(30):
            a, d = rng.uniform(0, 2 * math.pi), rng.uniform(rmin, 2 * rmin)
            p = (base[0] + d * math.cos(a), base[1] + d * math.sin(a))
            if not (box[0] <= p[0] < box[1] and box[2] <= p[1] < box[3]):
                continue
            gx, gy = int(p[0] // cell), int(p[1] // cell)
            if all(math.dist(p, q) >= rmin for i in range(gx - 2, gx + 3) for j in range(gy - 2, gy + 3)
                   if (q := grid.get((i, j)))):
                add(p); break
        else:
            active.pop(k)
    rnd = np.array(pts)
    zone = lat[:, 0] < xh + A
    li, ri = linear_sum_assignment(np.linalg.norm(lat[zone][:, None] - rnd[None], axis=2))
    pos = lat.copy()
    zi = np.nonzero(zone)[0][li]
    pos[zi] = lat[zi] + (rnd[ri] - lat[zi]) * (1 - w(lat[zi, 0]))[:, None]
    keep = ~zone; keep[zi] = True                  # lattice points left without a random partner are dropped
    lat, pos = lat[keep], pos[keep]

    ys, xs = (np.mgrid[0:TILE * S, 0:TILE * S] + 0.5) / S
    qx, qy = np.abs(xs - CX) - (W / 2 - R), np.abs(ys - CY) - (H / 2 - R)
    sd = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R
    ink = (sd <= 0) & (xs >= XS)                   # the solid
    ramp = (sd <= 0) & (xs < XS)
    p = np.column_stack([xs[ramp], ys[ramp]])
    # mark shape per coverage: round dot (k = 0) below C1, then a rounded hexagon of exact area c * cell whose
    # walls stop at SYN_WALL (C2); then the paper web keeps that width and retracts from each edge's middle
    # into the cell corners (paper = wall band within L of a corner, L -> 0): no wall ever thinner than 2 px
    cell_area, C1, SYN_WALL = math.sqrt(3) / 2 * A * A, 0.35, 2.2
    e1, e2 = A * math.sqrt(C1 * math.sqrt(3) / (2 * math.pi)), (A - SYN_WALL) / 2
    es = np.linspace(e1, e2, 600)                                       # extent k + rho
    rhos = e1 * (e2 - es) / (e2 - e1)
    covs = (2 * math.sqrt(3) * (es - rhos) ** 2 + 4 * math.sqrt(3) * (es - rhos) * rhos + math.pi * rhos ** 2) / cell_area
    C2 = covs[-1]
    Rc = A / math.sqrt(3)                                               # cell circumradius (corner distance)
    corners = np.array([[Rc, 0], [Rc / 2, A / 2]])
    hexnorm = lambda q: np.maximum(q[..., 1], 0.866025404 * q[..., 0] + 0.5 * q[..., 1])
    corner_d = lambda q: np.min(np.linalg.norm(q[..., None, :] - corners, axis=-1), axis=-1)
    g = (np.mgrid[0:300, 0:300].reshape(2, -1).T + 0.5) / 300 * [Rc, A / 2]   # one quarter cell, sampled
    g = g[hexnorm(g) <= A / 2]
    band = A / 2 - hexnorm(g) < SYN_WALL / 2
    Ls = np.linspace(0, math.hypot(Rc / 2, SYN_WALL / 2) + 0.01, 300)
    covL = np.array([1 - (band & (corner_d(g) < L)).mean() for L in Ls])     # falls from 1 to C2 as L grows
    cl = cKDTree(lat).query(p)[1]                  # Voronoi cell of each pixel
    cc = c(lat[:, 0])
    e = np.where(cc < C1, A * np.sqrt(cc * math.sqrt(3) / (2 * math.pi)), np.interp(np.minimum(cc, C2), covs, es))
    rho = np.where(cc < C1, e, np.interp(np.minimum(cc, C2), covs, rhos))
    L = np.interp(-cc, -covL, Ls)                  # covL is decreasing in L
    pc = pos[cl]                                   # marks stay whole: drop any not fully inside the card
    qx, qy = np.abs(pc[:, 0] - CX) - (W / 2 - R), np.abs(pc[:, 1] - CY) - (H / 2 - R)
    whole = (np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R <= -e[cl]) | (cc[cl] >= 0.9)
    q = np.abs(p - pc)                             # signed distance to a flat-top hexagon of apothem k (iq)
    k = (e - rho)[cl]
    d = np.minimum(-0.866025404 * q[:, 0] + 0.5 * q[:, 1], 0)
    hx, hy = q[:, 0] + 2 * d * 0.866025404, q[:, 1] - 2 * d * 0.5
    hx, hy = hx - np.clip(hx, -0.577350269 * k, 0.577350269 * k), hy - k
    late = cc[cl] >= C2
    web = (A / 2 - hexnorm(q) < SYN_WALL / 2) & (corner_d(q) < L[cl])
    ink[ramp] = np.where(late, ~web, (np.hypot(hx, hy) * np.sign(hy) - rho[cl] <= 0) & whole)
    cov = ink.reshape(TILE, S, TILE, S).mean(axis=(1, 3))[..., None]
    Image.fromarray((BG * (1 - cov) + INK * cov).astype(np.uint8)).save(out)
    print(f"synthetic ramp: {out}")


def synthetic_stochastic(out, seed=7):
    """The stochastic (blue-noise) reference that must PASS under --screen stochastic, same card as synthetic_ramp.
    1. One progressively ranked blue-noise set (brandkit.progressive_blue_noise: Bridson, min distance D, ranked by
       farthest point, so every prefix is evenly spread). Point i (rank u_i) is shown where u_i < c(x) / C_D: the
       density follows the coverage at a fixed radius R0 (D = 2.5 * R0) up to the set's full density at C_D.
    2. Beyond C_D every point is shown and the radius grows (r = R0 * sqrt(c / C_D) * scale(x)); the disks merge.
    3. A morphological closing of radius WALL / 2 where c >= the touching exemption fills every paper gap or hole
       thinner than WALL = 2.2 px (no hairlines, no slivers); then the solid.
    4. scale(x) is calibrated (a few passes at 2x) so the rendered column coverage follows c(x) = 0.04 + 0.96 *
       smoothstep. Everything is clipped to the card."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import brandkit
    S = 4
    BG, INK = np.array([249, 250, 245]), np.array([28, 28, 28])
    W, H, R, CX, CY = 620, 400, 64, 490, 512
    XL, YT = CX - W / 2, CY - H / 2
    XS = XL + 0.72 * W
    R0, WALL = 3.9, 2.2
    D = 2.5 * R0
    sstep = lambda t: (lambda u: u * u * (3 - 2 * u))(np.clip(t, 0, 1))
    c = lambda x: np.where(x >= XS, 1.0, 0.04 + 0.96 * sstep((x - XL) / (XS - XL)))
    box = (XL - D, XS + D, YT - D, YT + H + D)
    pts = brandkit.progressive_blue_noise(10 ** 6, box, D, seed)
    C_D = len(pts) / ((box[1] - box[0]) * (box[3] - box[2])) * math.pi * R0 ** 2
    u = np.arange(len(pts)) / len(pts)
    cp = c(pts[:, 0])
    show = u < np.minimum(cp / C_D, 1)
    qx, qy = np.abs(pts[:, 0] - CX) - (W / 2 - R), np.abs(pts[:, 1] - CY) - (H / 2 - R)
    sd = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R
    show &= (sd <= -R0 * np.sqrt(np.maximum(cp / C_D, 1)) * 1.3) | (cp >= TOUCH_OK_COVERAGE_STOCHASTIC + 0.06)  # whole dots

    def card(s):
        ys, xs = (np.mgrid[0:TILE * s, 0:TILE * s] + 0.5) / s
        qx, qy = np.abs(xs - CX) - (W / 2 - R), np.abs(ys - CY) - (H / 2 - R)
        return (np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R <= 0), xs

    def render(scale, s):
        rad = np.where(cp <= C_D, R0, R0 * np.sqrt(cp / C_D) * np.interp(pts[:, 0], xc, scale))
        rad = np.where(cp < TOUCH_OK_COVERAGE_STOCHASTIC + 0.06, np.minimum(rad, 0.95 * D / 2.4), rad)   # gap rule
        im = Image.new("1", (TILE * s, TILE * s), 0)
        dr = ImageDraw.Draw(im)
        for (x, y), r in zip(pts[show] * s, rad[show] * s - 0.5):     # PIL's bbox is inclusive: half a px less
            dr.ellipse((x - r, y - r, x + r, y + r), fill=1)
        inside, xs = card(s)
        ink = np.asarray(im, bool) | (inside & (xs >= XS))
        rp = int(round(WALL / 2 * s))
        st = np.hypot(*np.mgrid[-rp:rp + 1, -rp:rp + 1]) <= rp
        late = c(xs) >= TOUCH_OK_COVERAGE_STOCHASTIC + 0.06                # after the gap-rule cap
        ink = np.where(late, ndimage.binary_closing(ink, structure=st, border_value=0), ink)
        return ink & inside

    xc = np.linspace(XL, XS, 48)
    scale = np.ones_like(xc)
    rows = slice(int(YT + 0.2 * H), int(YT + 0.8 * H))
    for _ in range(5):
        ink = render(scale, 2).reshape(TILE, 2, TILE, 2).mean(axis=(1, 3))
        meas = np.interp(xc, np.arange(TILE) + 0.5, ndimage.uniform_filter1d(ink[rows].mean(axis=0), 24))
        want = c(xc)
        scale = np.clip(scale * np.where(want > C_D, np.clip(np.sqrt(want / np.maximum(meas, 1e-3)), 0.85, 1.15), 1),
                        0.7, 2.5)
    cov = render(scale, S).reshape(TILE, S, TILE, S).mean(axis=(1, 3))[..., None]
    Image.fromarray((BG * (1 - cov) + INK * cov).astype(np.uint8)).save(out)
    print(f"synthetic stochastic ramp: {out} ({len(pts)} points, full density at coverage {C_D:.2f})")


# ---------------------------------------------------------------- main
if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog="Order checks (|psi6|, 1-CV(NN) band step and drawdown) report |difference| minus "
                                        f"{ORDER_NOISE_SE:g} standard errors of the band means, so the verdict doesn't flip "
                                        "with the render's seed; thresholds and their calibration: the constants at the "
                                        "top of this script and docs/tooling.md (P1). Overhang: ink past the solid card's top/bottom/right edge "
                                        f"(farthest <= {OVERHANG_PX} px, share <= {OVERHANG_SHARE:.1%}). Bbox margin imbalance: "
                                        f"|left-right| and |top-bottom| margins of the ink bbox <= {BBOX_IMBALANCE:.0%} of the tile "
                                        "(stills only); reported next to the optical centre (centroid + bbox, 3%), which it "
                                        "does not relax: it only caps how far the bbox alone may sit off-centre.")
    ap.add_argument("render", nargs="*", help="render-1024.png or .svg (several: each is reviewed)")
    ap.add_argument("--axis", choices=("x", "y"), default="x", help="transition axis (default x)")
    ap.add_argument("--region", help="x0,y0,x1,y1 in 1024 px (default: the ink bounding box)")
    ap.add_argument("--home", action="store_true", help="also render home-screen rows with Apple's icons")
    ap.add_argument("--out", help="sheet path (default: $TMPDIR/design-review/<render's last 3 folders>/<name>-review.png)")
    ap.add_argument("--screen", choices=("lattice", "stochastic"), default="lattice",
                    help="lattice (default): order must rise to a hex lattice; stochastic: blue noise, order must "
                         "stay even (NN floor, no clumps or voids), touching allowed from coverage "
                         f"{TOUCH_OK_COVERAGE_STOCHASTIC}")
    ap.add_argument("--mode", choices=("halftone", "outline", "flat"), default="halftone",
                    help="halftone (default): the dots-into-a-card ramp checks above; outline: a card outline traced "
                         "by separate dots (count, spacing, edge gaps, size rhythm, symmetry, 58/29 px legibility); "
                         "flat: a solid flat mark (thinnest stroke / gap, what fades or closes at 58/29 px)")
    ap.add_argument("--dots", type=int, metavar="N", help="outline mode: the expected dot count (default: report only)")
    ap.add_argument("--make-synthetic", metavar="OUT.png", help="write the smooth reference ramp (of --screen) and review it")
    ap.add_argument("--watch", action="store_true", help="re-run when a render changes; one PASS/FAIL line per run")
    ap.add_argument("--frames", action="append", metavar="DIR|GLOB",
                    help="an animation's frames (a directory or a quoted glob): every metric on every frame, worst "
                         "frame per metric; repeatable")
    a = ap.parse_args()
    if a.make_synthetic:
        (synthetic_ramp if a.screen == "lattice" else synthetic_stochastic)(a.make_synthetic)
        a.render = a.render or [a.make_synthetic]
    if not a.render and not a.frames:
        ap.error("render path (or --frames) required")
    if a.out and (len(a.render) > 1 or a.frames):
        ap.error("--out takes one render (frame sheets go to $TMPDIR/design-review/<frames' folders>/)")
    if a.watch and a.frames:
        ap.error("--watch takes renders, not --frames")
    if a.mode != "halftone" and (a.frames or a.make_synthetic):
        ap.error(f"--mode {a.mode} takes renders (no --frames, no --make-synthetic)")
    region = tuple(int(v) for v in a.region.split(",")) if a.region else None
    if a.mode != "halftone":
        run = ((lambda p, quiet=False: review_outline(p, a.out, a.home, quiet=quiet, expected=a.dots))
               if a.mode == "outline" else (lambda p, quiet=False: review_flat(p, a.out, a.home, quiet=quiet)))
        if a.watch:
            watch(a.render, lambda p: run(p, quiet=True))
            sys.exit(0)
        fails = 0
        for k, path in enumerate(a.render):
            if k:
                print()
            fails += run(path)[0]
        sys.exit(1 if fails else 0)
    if a.watch:
        watch(a.render, lambda p: review(p, a.axis, region, a.out, a.home, quiet=True, screen=a.screen))
        sys.exit(0)
    fails = 0
    for k, path in enumerate(a.render):
        if k:
            print()
        fails += review(path, a.axis, region, a.out, a.home, screen=a.screen)[0]
    for k, spec in enumerate(a.frames or []):
        paths = frame_paths(spec)
        if not paths:
            ap.error(f"--frames {spec}: no .png/.svg frames")
        if k or a.render:
            print()
        fails += review_frames(paths, a.axis, region, a.home, a.screen)
    sys.exit(1 if fails else 0)
