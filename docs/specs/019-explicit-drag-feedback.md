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
3. **The dial** (new `RatingDial(value: Double)` in DesignSystem; replaces `ConfidenceDots` in Study; `value` is
   the ease 0…1, `m = |value − 0.5| × 2`, sign = side). Custom-drawn because it is the brand's dot language.
   - **24 dots** on a circle of radius **R + 16 pt** around the touch-down point (the finger stays inside the
     ring at 100 %). Dot `k` (0…23) sits at `(k + 0.5) × 15°` from 12 o'clock, clockwise for the positive side,
     counter-clockwise for the negative side.
   - **Filled count** `n(m)`: `12 × m / 0.3` for `m < 0.3`, then `12 + 12 × (m − 0.3) / 0.45`, max 24. So **half
     the ring = Hard / Got it, the full ring = Forgot / Easy**, exactly at 011's bin edges (0.35 / 0.65 and
     0.125 / 0.875 in ease). Dot `k` has fill `clamp(n − k, 0, 1)`.
   - **Dot states**: track (fill 0): 4 pt, `Theme.secondaryInk` at 45 % opacity. Pending (filled, grade not yet
     reached): diameter `4 + 2 × fill` pt, `Theme.secondaryInk`, opacity `0.4 + 0.6 × fill`. Armed (dot `k` <
     12 once in Hard/Got it, all 24 once in Forgot/Easy): 6 pt, `Theme.ink`, opacity 1.
   - **Positive dots are filled discs; negative dots are rings** (1.5 pt `strokeBorder`, same diameter). So Easy
     and Forgot (both full rings) and Hard and Got it (both half rings) never look alike, in grayscale too.
   - **Threshold pulse**: when the grade stage rises (none → Hard/Got it → Forgot/Easy), the armed dots scale
     1 → 1.3 → 1 over 0.2 s (`.keyframeAnimator`, ease-out then ease-in; no spring), together with 011's haptic.
     This includes Hard → Forgot, where the left label changes a second time. None when the stage drops.
     Reduce Motion: no pulse.
   - Colors: `Theme.ink` / `Theme.secondaryInk` only. No `Theme.accent` (the counter already holds the screen's
     one pink element).
4. **The card text fades** from opacity 1 to **0.3** across the dead zone (`1 − 0.7 × min(m / 0.3, 1)`), so an
   accidental nudge doesn't hide the answer and the dial reads clearly once armed. The dial is drawn **above** the
   card text during a drag; the `textHalo` patches go away.
5. **The rating row echoes the target.** While a drag is held and `p ≠ 0`: the button on the drag's side shows the
   grade the release would give (left: "Hard" / "Forgot"; right: "Got it" / "Easy"; in the dead zone the side's
   first grade, "Hard" / "Got it", in regular weight), **semibold once armed**; the other button turns
   `Theme.secondaryInk`. Label changes use `.contentTransition(.opacity)`. The buttons keep their positions, their
   ids `study.rate.again` / `study.rate.good` and their actions (a tap still sends `again` / `good`). At `p ≈ 0`
   and after release, the row is at rest ("Forgot" / "Got it", ink, regular).
6. **Release**: in a grade, the armed dial scales to **1.12** while fading out over `Theme.Motion.standard`
   (0.25 s); the row label stays until the next card. In the dead zone (cancel), the dial **shrinks to 0.6**
   toward the touch point while fading (same 0.25 s), the text returns to 1, the row returns to rest.
   Reduce Motion: both releases are opacity-only.
7. **Reduce Motion** otherwise: the fill follows the finger continuously (it is a fill, not a movement); only the
   pulse and the release scales are dropped. (011's five-bin drawings go away with the noise ring.)

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `StudyFeature.swipeFraction(translation:cardWidth:)` returns `clamp(dx − dy, −d, d) / width`: for width 370, (+46, 0), (0, −46), (+32.5, −32.5) → +0.124…+0.125; (−46, 0), (0, +46), (−32.5, +32.5) → −0.124…−0.125; (−40, −40) and (+40, +40) → 0; (+200, 0) → 0.54 (ease clamps); width 0 → 0 | unit |
| 2 | Through `ease(forSwipe:)` + `rating(forEase:)`, a drag of 0.13 card width up, right or up-right gives `good`, 0.22 gives `easy`; down, left or down-left gives `hard` / `again`; up-left / down-right at any length give `nil` | unit |
| 3 | `RatingPan` begin rule (pure function `shouldBegin(velocity:isScrollable:)`): not scrollable → true for every non-zero velocity; scrollable → false for (0, ±100) and (±50, ±100) (within 30° of vertical), true for (±100, 0), (±70, −70), (±60, ±100)… i.e. `|dx| ≥ 0.58·|dy|` | unit |
| 4 | `RatingDial` layout (pure, `RatingDialLayout(value:)`): 24 dots; at value 0.5 every dot is track; at 0.65 exactly 12 dots armed, filled discs, clockwise from 12 o'clock (first at 7.5°); at 0.35 the same 12 armed as rings, counter-clockwise; at 0.875 and 1.0 all 24 armed discs; at 0.125 and 0 all 24 armed rings; at 0.575 (m = 0.15) 6 dots pending, none armed; the stage changes exactly where `rating(forEase:)` changes, checked at every 0.005 of value | unit (DesignSystemTests + one StudyFeatureTests consistency test) |
| 5 | Held drag (`-studySwipePreview <f>` holds the translation `(f·w, 0)` as today; new `-studySwipePreviewUp <f>` holds `(0, −f·w)`): `study.swipeRing` exists, its accessibility value is the grade ("Got it" +0.13, "Easy" +0.22, "Hard" −0.13, "Forgot" −0.22, "None" +0.04; "Easy" for Up 0.22) | UI (held, screenshots `study-drag-<grade>` light + dark: the rings and the 45 % track must read on dark) |
| 6 | Held drag: `study.rate.good`'s label reads "Easy" at +0.22 and "Got it" at +0.13; `study.rate.again`'s label reads "Forgot" at −0.22 and "Hard" at −0.13; at +0.04 the right label reads "Got it"; ids unchanged | UI |
| 7 | A real drag up (0.22 card width) on a revealed short card sends `easy`; a real drag down (0.22) sends `again`; a drag up-left sends nothing and the card stays revealed | UI (stub body) |
| 8 | Long card (011 #10 stub): a vertical drag scrolls and shows no ring; a drag starting at 45° up-right shows the ring and rates | UI (stub) |
| 9 | 011 #6–#9, #11–#14, #17, #19, #20 still pass (release, cancel, unrevealed, editing, double-tap, haptics, VoiceOver actions, live API) | UI + unit (regression) |
| 10 | Visual: dial geometry, states, ring-vs-disc, text fade, row echo, pulse, release scales match "What changes" 3–6; Reduce Motion drops pulse and scales | design-critic (screenshots) + device check |

## Accessibility identifiers
Unchanged: `study.card`, `study.swipeRing` (label "Rating", value = grade or "None"), `study.rate.again`,
`study.rate.good`. While a drag is held the two buttons' labels follow the echo (VoiceOver users don't drag).

## Out of scope
- Color per grade, text inside the dial, a second axis meaning anything else.
- Storing the continuous value (backlog 22).
