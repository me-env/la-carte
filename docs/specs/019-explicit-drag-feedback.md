# 019 — Explicit rating drag: a dot dial that fills, any direction

Status: ready
Owners: ios-engineer (StudyFeature) + design-lead or ios-engineer (`RatingDial` in DesignSystem)
Depends on: [011](011-ratings.md) (ratings, drag), [018](018-auto-refresh.md) (no pull-to-refresh: down is free)
Supersedes in 011: the noise/order ring, "one dimension" (horizontal only), "no text, no color", AC #3, #5 (visual
part), #15, #16, #18. Everything else in 011 (bins, haptics, `canRate`, release, VoiceOver actions, ids) stays.
Renders (mock, light): `docs/design/renders/019-drag/` (before vs after, both directions, release, 7 directions).

## Goal
User feedback 2026-11-22: "the feedback when we slide is not super clear, make it way more explicit, like with
more dots". And: "up or right, or diagonal up-right, is the positive side; down or left the negative side".
The held drag must say, at a glance, **which grade a release gives and when a threshold is crossed**.

## What changes
1. **Direction: a projection on the up-right diagonal.** With the pan translation `(dx, dy)` in screen points
   (y down) and `d = √(dx² + dy²)`: `p = clamp(dx − dy, −d, d)`. Right, up and up-right all give `p = d`; left,
   down and down-left give `−d`; up-left and down-right give ~0. The fraction sent to the reducer is
   `f = p / cardWidth`; `ease(forSwipe:)`, the bins and the haptics are unchanged (so 100 % = `p = R`, R = 0.25 ×
   card width, 92 pt on iPhone 17 Pro). Why this formula: the three positive directions feel the same distance,
   and the ambiguous diagonals cancel instead of guessing.
2. **When the pan begins** (`gestureRecognizerShouldBegin`): any first direction **when the card's content fits**
   (018 removed pull-to-refresh, and a fitting card doesn't scroll). When the content **scrolls** (long card), a
   first movement within **30°** of vertical (`|dx| < 0.58·|dy|`) is left to the scroll view; anything else begins
   the rating drag. Once begun, every direction counts (`p` uses the full translation). `HorizontalPan` becomes
   `RatingPan`, reporting the full translation (`CGSize`) and taking an `isScrollable` flag.
3. **The dial** (`RatingDial(value: Double, radius:)` in DesignSystem; replaces `ConfidenceDots` in Study; `value`
   is the ease 0…1, `m = |value − 0.5| × 2`, sign = side). Custom-drawn (`Canvas`) because it is the brand's dot
   language. Revised 2026-11-22 after user feedback on the first dial ("the Forgot side being just empty circles is
   not super clear; many more points, disorganized or organized, different sizes when disorganized, the same size
   when organized"): **the dots' order is the grade**, not a fill count and not rings vs discs.
   - **96 dots**: 3 rings at **0.82 / 0.91 / 1.0 × radius** (radius = R + 16 pt around the touch-down point)
     holding **29 / 32 / 35 dots**, proportional to the ring's radius, so the spacing along every ring is the same
     (~19.3 pt): smooth rings, not radial spokes (user feedback 2026-11-22: "the bigger circles should have more
     dots"). Dot `j` of a ring of `n` sits at `(j + φ) × 360° / n` from 12 o'clock, `φ` = 0 / ½ / 0 (inner / middle /
     outer): the top is staggered, not a spoke, and the ordered dial is mirror-symmetric; ordered dot **4.5 pt**.
   - **Disorder** `c` (0 = ordered, 1 = scattered), one look per grade: **Forgot 1 · Hard 0.45 · rest 0.3 ·
     Got it 0.2 · Easy 0**. Each stretch (dead zone `m < 0.3`; first grade `0.3 ≤ m < 0.75`) **holds its own value
     for the first 70 % of its travel**, then ramps linearly to the next grade's value at the bin edge, so a grade
     reads as itself, not a blend; clamped beyond `m = 0.75`. The fully scattered layout (Forgot) is computed once
     and is **deterministic** (SplitMix64 seeded by dot index, so it never flickers): angle drift `±1` pitch of its ring,
     radial drift `±15 %` of radius, size `0.6…1.8 ×` (squared, so most scattered dots are small, a few large),
     then pushed apart (80 passes) until **no two dots' edges are closer than 8 pt** and kept in the band, so the
     scatter is even, not clumped (no empty sector over 2 pitches, nothing inside 0.66 R where the card text
     is). Position and size interpolate linearly by `c` from the lattice to that scatter, and every frame's blend is
     spaced the same way to a gap of `1.5 + 6.5 × c` pt (so dots never touch mid-drag; Easy's lattice is untouched). So the
     negative side **scatters with varied sizes** (fully at Forgot) and the positive side **settles into the even
     3-ring lattice, all one size** (exactly at Easy); the finger's movement moves every dot continuously.
   - **Ink**: before a grade (dead zone) all dots are `Theme.secondaryInk` at 60 % opacity; once Hard / Got it or
     Forgot / Easy is reached, all dots are `Theme.ink` at 100 %. No `Theme.accent` (the counter already holds
     the screen's one pink element), no colour per grade.
   - **Threshold pulse**: when the grade stage rises (none → Hard/Got it → Forgot/Easy), every dot scales
     1 → 1.3 → 1 over 0.2 s (`KeyframeAnimator`, ease-out then ease-in; no spring), together with 011's haptic.
     This includes Hard → Forgot. None when the stage drops. Reduce Motion: no pulse (the order still follows the
     finger: it is a state, not a movement).
4. **The card text fades** from opacity 1 to **0.3** across the dead zone (`1 − 0.7 × min(m / 0.3, 1)`), so an
   accidental nudge doesn't hide the answer and the dial reads clearly once armed. The dial is drawn **above** the
   card text during a drag; the `textHalo` patches go away.
5. **The rating row echoes the target.** While a drag is held and `p ≠ 0`: the button on the drag's side shows the
   grade the release would give (left: "Hard" / "Forgot"; right: "Got it" / "Easy"; in the dead zone the side's
   first grade, "Hard" / "Got it", in regular weight), **semibold once armed**; the other button turns
   `Theme.secondaryInk`. Label changes use `.contentTransition(.opacity)`. The buttons keep their positions, their
   ids `study.rate.again` / `study.rate.good` and their actions (a tap still sends `again` / `good`). At `p ≈ 0`
   and after release, the row is at rest ("Forgot" / "Got it", ink, regular).
6. **Release** (revised 2026-11-22, user feedback: "when you pick Easy or Got it you get some dopamine"; constraint:
   "I don't want it to increase the time to the next question").
   - **Timing**: the release sends the rating at once and the next card starts its fade-in at once, exactly as
     before. The reward is an **overlay** playing over the next card: the dial (`RatingDial(…, release:)`) stays
     in `StudyView` for the reward's duration, takes no touches, is hidden from accessibility, and a **new drag
     cancels it** (the dial goes straight back to following the finger). Nothing in the reducer waits for it.
   - **Got it** (`Release.settle`, 0.5 s): the dots settle from their slight disorder into the perfect rings
     (critically damped, no overshoot, done by 0.28 s); every dot ticks once as it lands (size 1 → 1.12 → 1,
     centred at 0.24 s, ±0.08 s); then the dial grows to 1.08 while fading out (0.28 → 0.5 s). Haptic:
     `.success` at release.
   - **Easy** (`Release.burst`, 0.6 s): the same settle, faster (done by 0.2 s); a ripple runs out through the
     rings, inner first, 70 ms apart (centres 0.12 / 0.19 / 0.26 s, ±0.06 s): each ring steps out (3 pt, never
     touching the next ring; the outer ring 6 pt) and its dots swell 1.3×, a bigger event than Got it's tick; then the dial grows to 1.15 while fading out (0.3 → 0.6 s).
     Haptics: `.success` at release and a heavy impact at 0.26 s, as the ripple reaches the outer ring.
   - **Hard / Forgot**: neutral, no reward: the dial fades while shrinking to 0.94 over `Theme.Motion.standard`.
   - **Cancel** (dead zone): the dial shrinks to 0.6 toward the touch point while fading (0.25 s), the text
     returns to 1, the row returns to rest. The row label stays until the next card after a grade.
   - **Reduce Motion**: nothing moves; Got it and Easy fade out in 0.15 s with their haptics; Hard / Forgot /
     cancel fade (opacity only).
7. **Reduce Motion** otherwise: the fill follows the finger continuously (it is a fill, not a movement); only the
   pulse, the release scales and the reward's movement are dropped. (011's five-bin drawings go away with the noise ring.)

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `StudyFeature.swipeFraction(translation:cardWidth:)` returns `clamp(dx − dy, −d, d) / width`: for width 370, (+46, 0), (0, −46), (+32.5, −32.5) → +0.124…+0.125; (−46, 0), (0, +46), (−32.5, +32.5) → −0.124…−0.125; (−40, −40) and (+40, +40) → 0; (+200, 0) → 0.54 (ease clamps); width 0 → 0 | unit |
| 2 | Through `ease(forSwipe:)` + `rating(forEase:)`, a drag of 0.13 card width up, right or up-right gives `good`, 0.22 gives `easy`; down, left or down-left gives `hard` / `again`; up-left / down-right at any length give `nil` | unit |
| 3 | `RatingPan` begin rule (pure function `shouldBegin(velocity:isScrollable:)`): not scrollable → true for every non-zero velocity; scrollable → false for (0, ±100) and (±50, ±100) (within 30° of vertical), true for (±100, 0), (±70, −70), (±60, ±100)… i.e. `|dx| ≥ 0.58·|dy|` | unit |
| 4 | `RatingDial` layout (pure, `RatingDialLayout(value:radius:)`): 96 dots; at 0.875 and 1.0 disorder 0, every dot exactly on its lattice point (rings of 29 / 32 / 35, equal pitch) and all 4.5 pt; at 0.125 and 0 disorder 1, some dot > 15 pt off the lattice, sizes spread > 3 pt, no two dots' edges closer than 8 pt (and never closer than 1.5 pt at any value, checked every 0.05), no empty sector over 2 pitches, no dot inside 0.66 R; disorder is 1 / 0.45 / 0.3 / 0.2 / 0 at values 0.125 / 0.35 / 0.5 / 0.65 / 0.875, the same at 0.25 / 0.45 / 0.8 (held), and never rises from value 0 to 1; the same value gives the same layout; every dot (pulsed) fits the frame; the stage changes exactly where `rating(forEase:)` changes, checked at every 0.005 of value | unit (DesignSystemTests + one StudyFeatureTests consistency test) |
| 5 | Held drag (`-studySwipePreview <f>` holds the translation `(f·w, 0)` as today; new `-studySwipePreviewUp <f>` holds `(0, −f·w)`): `study.swipeRing` exists, its accessibility value is the grade ("Got it" +0.13, "Easy" +0.22, "Hard" −0.13, "Forgot" −0.22, "None" +0.04; "Easy" for Up 0.22) | UI (held, screenshots `study-drag-<grade>` light + dark: the scattered and the 60 % dead-zone dots must read on dark) |
| 6 | Held drag: `study.rate.good`'s label reads "Easy" at +0.22 and "Got it" at +0.13; `study.rate.again`'s label reads "Forgot" at −0.22 and "Hard" at −0.13; at +0.04 the right label reads "Got it"; ids unchanged | UI |
| 7 | A real drag up (0.22 card width) on a revealed short card sends `easy`; a real drag down (0.22) sends `again`; a drag up-left sends nothing and the card stays revealed | UI (stub body) |
| 8 | Long card (011 #10 stub): a vertical drag scrolls and shows no ring; a drag starting at 45° up-right shows the ring and rates | UI (stub) |
| 9 | 011 #6–#9, #11–#14, #17, #19, #20 still pass (release, cancel, unrevealed, editing, double-tap, haptics, VoiceOver actions, live API) | UI + unit (regression) |
| 10 | Visual: scattered (varied sizes) toward Forgot, ordered (one size) toward Easy, readable at a glance on iPhone 17 Pro light/dark/forest; ink once armed; text fade, row echo, pulse, release scales match "What changes" 3–6; Reduce Motion drops pulse and scales | design-critic (screenshots) + device check |
| 11 | Release reward (pure, `RatingDialReward` / `RatingDial.Release`): only values ≥ 0.65 earn one (≥ 0.875 burst); each starts at the released layout, settles monotonically to fully ordered by 0.3 s, ends at opacity 0 and scale > 1 at its duration (0.5 / 0.6 s), Easy grows more and lasts longer; Easy's ripple peaks inner → outer and its second beat lands on the outer ring's peak; Got it never pushes rings; no two dots touch at any frame; Reduce Motion: 0.15 s, opacity only. **The next card is never delayed**: with a clock that never advances, a Got it / Easy release still sends the review and shows the next card | unit (DesignSystemTests `RatingDialRewardTests`, StudyFeatureTests `StudyReleaseTimingTests`) + design-critic (frame strip `dial-release-*` from `RenderTests`) + device check (haptics) |

## Accessibility identifiers
Unchanged: `study.card`, `study.swipeRing` (label "Rating", value = grade or "None"), `study.rate.again`,
`study.rate.good`. While a drag is held the two buttons' labels follow the echo (VoiceOver users don't drag).

## Out of scope
- Color per grade, text inside the dial, a second axis meaning anything else.
- Storing the continuous value (backlog 22).
