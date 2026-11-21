# 011 — Ratings: two buttons, confidence dots

Status: ready
Owners: ios-engineer (design-lead fills "Design notes" first, design-critic checks them). No API work.
Depends on: 001 (study), 006 (refresh rule), **010 (inline edit) merged first** (same view, uses `editing`). Independent
of 009 (draft); if 009 lands, its haptics (#8) apply to both rating paths unchanged.
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg (one thing centered, quiet text
buttons at the bottom; nothing new on screen at rest).

## Goal
Rating gets simpler: two buttons, "Forgot" and "Got it", cover most reviews. For a finer answer, the user drags on
the revealed card. A ring of dots appears around the point where the finger came down. Dragging toward "forgot"
(left) scatters the dots into noise; dragging toward "easy" (right) settles them into a perfectly regular ring. How
ordered the dots are is how sure the user felt. No text, no color: monochrome ink dots, the same visual language as
the logo route ("lost data points resolving into structure", `docs/design/brand/explorations/round5/`). On release the
app turns that continuous value into one of the four ratings the API already takes.

## User stories
- As the user, I reveal a card and tap "Forgot" or "Got it".
- As the user, I drag on the revealed card: dots gather around my finger; sliding right orders them into a clean
  ring (easy), sliding left scatters them (forgot). I let go to rate.
- As the user, I slide back to where I started and let go, and nothing happens.
- As the user with VoiceOver, I pick any of the four answers from the card's actions.

## Interaction rules (decided)
- **Buttons**: "Forgot" (left, sends `again`) and "Got it" (right, sends `good`). Hard and Easy have no button.
- **The gesture**: a horizontal pan on the revealed card. It starts with no long press: the first movement must be
  mostly horizontal (`|dx| > |dy|`, after the system's ~10 pt slop). The ring appears then, **centered on the
  touch-down point** (pan location minus translation), not on every touch: taps, scrolls and pulls never show it.
- **One dimension.** Only the horizontal offset counts. Vertical movement after the axis lock is ignored. Why: vertical already belongs to scroll and pull-to-refresh
  (001, 006), and FSRS can't use a second dimension.
- **Continuous ease value** `v` in [0, 1]: `v = clamp(0.5 + dx / (2R), 0, 1)`, with ring radius **R = 0.25 x card
  width** (92 pt on iPhone 17 Pro, where `study.card` is 370 pt wide). So `v = 0` is the ring's left edge (forgot),
  0.5 is the touch-down point, and 1 is the right edge (easy). Going past the ring clamps. In card-width fractions
  `f = dx / cardWidth`, this is `v = clamp(0.5 + 2f, 0, 1)`.
  Why R = 0.25 x width: a ring 184 pt across fits the card with room to spare when the drag starts anywhere in the
  middle half of the card, and the full scale is a short thumb movement (92 pt each way).
- **Quantization on release** (FSRS takes only 4 grades). With `d = |v - 0.5| x 2` (0 at the touch-down point, 1 on
  the ring):

  | `v` | `d` | Distance (iPhone 17 Pro) | Rating on release |
  |---|---|---|---|
  | `v <= 0.125` | `>= 0.75`, left | 69 pt or more | `again` |
  | `0.125 < v <= 0.35` | 0.3 to 0.75, left | 28 to 69 pt | `hard` |
  | `0.35 < v < 0.65` | `< 0.3` | under 28 pt | nothing (cancel) |
  | `0.65 <= v < 0.875` | 0.3 to 0.75, right | 28 to 69 pt | `good` |
  | `v >= 0.875` | `>= 0.75`, right | 69 pt or more | `easy` |

  Why: the **dead zone** (28 pt) is well past the pan slop plus finger wobble, so "go back to where you started"
  reliably cancels. The **extremes start at 3/4 of the ring** and have no outer limit (the value clamps), so "reach
  the ring" always means Forgot or Easy, and an emphatic flick can't overshoot into a different grade. The **middle
  bands** are 41 pt wide, twice a fingertip, so Hard and Got it are easy to hold on purpose. It's symmetric: same
  effort for good and bad news.
- **The raw value is not sent.** Only the quantized `Rating` goes to `POST /cards/{id}/review`; the API contract does
  not change. Storing the continuous value is backlog item 22.
- **Release commits** exactly like tapping a button: the same review request, the same in-flight rule
  (`isReviewing`: buttons disabled), the same next-card / caught-up / offline flow from 001. On any release the ring
  fades out (`Theme.Motion.standard`); the card itself never moves. The next card appears instantly (001).
- **Dots, not color**: the ring is N monochrome dots (`Theme.ink` / `Theme.secondaryInk` only) whose **order**
  expresses `v`, morphing continuously while the finger moves:
  - `v = 1` (easy): a perfectly regular ring: equal spacing, equal size, on the circle of radius R.
  - `v = 0.5` (touch-down, cancel): a loosely ordered ring, mid noise.
  - `v = 0` (forgot): noise: positions jittered off the circle (radially and along it) and sizes varied.
  - In between: each dot's offset and size is its fixed random offset times a noise amount `(1 - v)` (or a curve
    chosen by design-lead), so the morph is continuous and reversible.
  - The noise is **seeded** (fixed per-dot offsets from a constant seed), so a given `v` always draws the same
    picture: deterministic for screenshots and tests, and no flicker while dragging.
  - The dots move only as the finger moves. No idle animation. There is no separate marker and nothing on the card
    is tinted.
  - The dot geometry comes from the **same DesignSystem primitive as the logo's dots** (design-lead owns it), so the
    rating dots and the logo stay one visual language.
- **Haptics: ticks at bin edges, no continuous rumble.** A continuous intensity haptic would buzz the whole time and
  would not tell the user where the edges are. Ticks are the iOS pattern for sliders and pickers. Rules:
  `.selection` when the value enters Hard or Got it, `.impact(weight: .medium)` when it enters Forgot or Easy, nothing
  when it enters the dead zone or on release (009's `.success` after the review is sent still applies). Since the
  ring has no text, the ticks are how the user feels the four grades.
- **Swipe is possible exactly when the rating buttons can be tapped**: `phase == .studying && isRevealed &&
  editing == nil && !isReviewing` (State's `canRate`). So: not before reveal (a sideways drag on an unrevealed card
  does nothing and does not reveal), not while editing (010), not while a review is in flight. Like the buttons
  (010: "rating is allowed while a save is in flight"), it stays allowed while an edit save is in flight.
- **Unchanged gestures**: a pan needs movement, so tap-to-reveal (001 #2) and double-tap-to-edit (010 #2) work as
  before. The axis lock leaves vertical scrolling of long cards and pull-to-refresh (006 #7) untouched.
- **Reduce Motion**: the dots don't morph continuously. They show the arrangement for the current **bin** (Forgot,
  Hard, neutral, Got it, Easy: the drawing at `v` = 0, 0.25, 0.5, 0.75, 1) and switch to the next arrangement with no
  motion when the bin changes, together with the haptic tick. The ring appears and disappears with opacity only.
  Haptics are unchanged.
- **Accessibility**: a visual-only cue is not enough, so
  - VoiceOver: the four ratings are accessibility actions ("Forgot", "Hard", "Got it", "Easy") on the card's text
    elements `study.front` and `study.back`, next to 010's "Edit". The card's `ScrollView` is a container VoiceOver
    never focuses, so the actions go where focus lands. They are present only when `canRate`. The two buttons remain.
  - There is no color to tell apart: the grades are read from **shape** (order vs scatter) in a single ink tone, so
    it works in grayscale and for color blindness. The haptic ticks give the grades without sight.
  - The ring is an accessibility element (`study.swipeRing`, label "Rating", value = the grade the release would give:
    "Forgot", "Hard", "Got it", "Easy" or "None"). It only exists during a drag, so VoiceOver users don't meet it.
    QA reads it.

## Acceptance criteria
Mock deck = `LA_CARTE_API=mock` (`serendipity`, `la carte`, `ephemeral`). Stub = `StubAPIServer` (records request
bodies, so a test can read the rating sent). Drags in UI tests: on `study.card`,
`coordinate(withNormalizedOffset: (0.5, 0.5)).press(forDuration: 0.05, thenDragTo: coordinate(withNormalizedOffset: (0.5 + f, 0.5)))`.
Normalized x is a fraction of the card's width (the `f` above). Use `f` = +0.13 (`v` 0.76, good), +0.22 (0.94,
easy), -0.13 (0.24, hard), -0.22 (0.06, again), +0.04 (0.58, cancel).

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | On a revealed card the bottom row shows exactly two buttons, `study.rate.again` "Forgot" on the left and `study.rate.good` "Got it" on the right; `study.rate.hard` and `study.rate.easy` do not exist. Before reveal neither exists (001 #3 unchanged) | UI (light, dark, forest) |
| 2 | Tapping "Forgot" sends `POST /cards/{id}/review` with `again`, "Got it" with `good`; the rest of 001 #4 holds (buttons disabled in flight, next card unrevealed, "2 to review") | unit + UI (stub body) |
| 3 | `StudyFeature.ease(forSwipe:)` maps `f` to `v = clamp(0.5 + 2f, 0, 1)`: -0.6 → 0, -0.25 → 0, -0.1 → 0.3, 0 → 0.5, 0.1 → 0.7, 0.25 → 1, 0.6 → 1 | unit |
| 4 | `StudyFeature.rating(forEase:)` quantizes per the table, boundaries included: 0 → again, 0.125 → again, 0.126 → hard, 0.35 → hard, 0.351 → nil, 0.5 → nil, 0.649 → nil, 0.65 → good, 0.874 → good, 0.875 → easy, 1 → easy | unit |
| 5 | While a revealed card is dragged, `swipeChanged(f)` sets `swipeEase` to `ease(forSwipe: f)`. `study.swipeRing` (the dots) exists, centered on the touch-down point, and its accessibility value is the grade for the current value ("Got it" at f = +0.13, "Easy" at +0.22, "Hard" at -0.13, "Forgot" at -0.22, "None" at +0.04). The two buttons stay visible. No text appears on screen | unit + UI (held via `-studySwipePreview`) |
| 6 | Releasing sends the review with the quantized rating, exactly as #2: f = +0.13 → `good`, +0.22 → `easy`, -0.13 → `hard`, -0.22 → `again`. The request body has only `rating` (no extra field). After each, the next card's front shows unrevealed, `study.remaining` decrements, and `study.swipeRing` does not exist | unit + UI (stub body, one card per grade) |
| 7 | Releasing in the dead zone (f = +0.04, or out to +0.22 and back to start) sends nothing; the ring disappears; the card is still revealed with both buttons enabled | unit + UI |
| 8 | A horizontal drag (f = +0.22) on an **unrevealed** card sends nothing, does not reveal it, and shows no ring; `swipeChanged` / `swipeEnded` change no state when `canRate` is false | unit + UI |
| 9 | While editing (010: `study.backField` focused), a horizontal drag sends no review and shows no ring; while a review is in flight, `swipeChanged` / `swipeEnded` change no state | unit + UI (editing case) |
| 10 | Long card (stub, ~200-character back, revealed): a vertical drag scrolls the back into view, shows no ring, sends nothing; a pull-down on the revealed card refreshes (006 #7: the card stays revealed) and shows no ring | UI (stub) |
| 11 | Double-tapping `study.back` on a revealed card still opens `study.backField` (010 #3); a single tap on the unrevealed card still reveals it (001 #2); neither shows a ring | UI (regression) |
| 12 | After a drag whose review fails, the screen shows "Can't reach your deck" (001 #7); retry brings back the same card, revealed, with the two buttons and no ring (`swipeEase == nil`) | unit + UI (stub review 500) |
| 13 | A due-cards response whose first card differs from the current one (refresh mid-drag) clears `swipeEase` along with `isRevealed`; a response with the same first card keeps it | unit |
| 14 | Haptics: `.selection` on entering Hard or Got it, `.impact(weight: .medium)` on entering Forgot or Easy; nothing on entering the dead zone or on release | review + device check |
| 15 | The dots morph continuously with `v`: a perfectly regular ring at `v` = 1, scattered noise at `v` = 0, in between proportionally; the same `v` always draws the same dots (seeded); they move only when the finger moves; the card never moves; the ring fades out on release with `Theme.Motion.standard`. Nothing bounces | unit (DesignSystem: layout for a given `v` is deterministic; `v` = 1 is evenly spaced on the circle) + screenshot review + device check |
| 16 | Reduce Motion: the dots show only the five bin arrangements (`v` = 0 / 0.25 / 0.5 / 0.75 / 1), switching without motion at bin edges; the ring appears and disappears by opacity only; haptics unchanged | review + device check (no Reduce Motion switch for UI tests) |
| 17 | VoiceOver: on a revealed card, `study.front` and `study.back` expose the actions "Forgot", "Hard", "Got it", "Easy" (plus 010's "Edit"), which send `ratingTapped` with `again` / `hard` / `good` / `easy`. None before reveal, while editing, or while a review is in flight | review + VoiceOver device check |
| 18 | No color: the dots use only `Theme.ink` / `Theme.secondaryInk` (each at least 3:1 against `Theme.background`, WCAG 1.4.11) in light, dark and forest, with no `Theme.accent` pink. The five held screenshots (#5) are told apart by shape alone, in grayscale | design-critic + screenshot review |
| 19 | Dynamic Type accessibility XL: the two buttons fit in the bottom slot, nothing clipped | UI (light) |
| 20 | Live API (`scripts/e2e.sh`): in `testStudy_revealRateToCaughtUp_liveAPI`, the first card is rated by a drag (f = +0.13, good) and the second with "Got it"; the test still ends on "All caught up" | UI (`_liveAPI`) |

## Screens & states
No new screen, and nothing new at rest: the row is "Forgot   Got it" (same quiet `.body` ink text buttons as 001,
centered, the row keeps its reserved height so the front never moves on reveal). During a drag, the ring of dots
floats over the card, centered on the touch-down point, above the text; the buttons stay where they are.

Screenshots (QA, `<screen>-<state>`), light + dark + forest: `study-revealed` (two buttons), `study-swipe-again`,
`study-swipe-hard`, `study-swipe-neutral` (f = +0.04), `study-swipe-good`, `study-swipe-easy` (dots held at each
value). Light only: `study-revealed-xl` (AX XL, #19).

**How QA holds a drag for a screenshot**: XCUITest's drag calls block until the finger lifts, so the held state comes
from a DEBUG-only launch argument `-studySwipePreview <f>` (UserDefaults argument domain, like `-theme`; `f` in
card-width fractions, the same unit as the drags). When it is set and `canRate` becomes true, `StudyView` acts as if
a finger came down at the card's center and is held at `f`: it draws the real dots and sends
`swipeChanged(f)` once. It never releases. Use the five `f` values above.

## TCA shape (iOS)
No new module, no new dependency. `StudyFeature` + `StudyView`, plus a dots view in `DesignSystem` (design-lead).

- State (new):
  ```swift
  var swipeEase: Double?            // continuous ease value 0...1 while a drag is held; nil = no ring
  var swipeRating: Rating? { swipeEase.flatMap(StudyFeature.rating(forEase:)) }   // what a release would send
  var canRate: Bool {               // buttons tappable == drag possible == VoiceOver actions present
    phase == .studying && isRevealed && editing == nil && !isReviewing
  }
  ```
- Mapping (reducer side, pure, unit-tested by #3 and #4):
  ```swift
  static let ringRadius = 0.25                    // fraction of the card's width
  static func ease(forSwipe fraction: Double) -> Double          // clamp(0.5 + fraction / (2 * ringRadius), 0, 1)
  static func rating(forEase ease: Double) -> Rating?            // bin edges 0.125 / 0.35 / 0.65 / 0.875
  ```
- Actions (new): `swipeChanged(fraction: Double)`, `swipeEnded(fraction: Double)`. The view sends the raw horizontal
  translation over the card width; it never decides a value or a rating. VoiceOver actions send the existing
  `ratingTapped(Rating)`.
- Logic:
  - `swipeChanged(f)`: `guard state.canRate`; `swipeEase = ease(forSwipe: f)`. It runs every frame. That's expected,
    since the dots follow it.
  - `swipeEnded(f)`: `guard state.canRate`; `swipeEase = nil`; `rating(forEase: ease(forSwipe: f))`: nil → `.none`,
    else the same path as `ratingTapped`. Move `ratingTapped`'s body (guard, `isReviewing = true`, 010's
    `editFailed = false`, cancel the load, run `review`) into a private helper `review(_ rating:, state:)` used by
    both (convention: shared logic in a helper, not an internal action).
  - `cardsResponse(.success)`: where it resets `isRevealed` (first id changed), also `swipeEase = nil`.
  - A cancelled pan (system interruption) sends `swipeEnded` with no rating, i.e. `swipeEnded(fraction: 0)`. The ring
    clears and nothing is sent.
- View (`StudyView`):
  - Horizontal pan on `study.card`, enabled only when `store.canRate`, that begins only when the first movement is
    mostly horizontal. Recommended: `UIGestureRecognizerRepresentable` wrapping a `UIPanGestureRecognizer` whose
    `shouldBegin` checks `|velocity.x| > |velocity.y|`, so the `ScrollView` pan and the refresh control keep vertical
    gestures. A SwiftUI `DragGesture` is fine if #10 passes on device and in UI tests.
  - Reports `translation.x / cardWidth` (`onGeometryChange` for the width) as `swipeChanged` / `swipeEnded`.
  - The touch-down point (where to center the ring) is visual-only `@State`. The ring's radius is
    `StudyFeature.ringRadius * cardWidth`. Everything else is read from the store: `if let ease = store.swipeEase`
    shows `ConfidenceDots(order: ease, radius:)`; with Reduce Motion the view passes the bin's fixed value instead
    (0 / 0.25 / 0.5 / 0.75 / 1).
  - Haptics: `.sensoryFeedback(trigger: store.swipeRating) { _, new in ... }` returning `.selection` for
    hard/good, `.impact(weight: .medium)` for again/easy, `nil` for nil (#14).
  - `@Environment(\.accessibilityReduceMotion)` for #16.
  - Copy lives with the view: `again` "Forgot", `hard` "Hard", `good` "Got it", `easy` "Easy" (one function used by
    the buttons, the VoiceOver actions and the ring's accessibility value).
  - `-studySwipePreview` handling under `#if DEBUG` only (see "Screens").
- DesignSystem (design-lead): `ConfidenceDots(order: Double, radius: CGFloat)`, built on the **same dot primitive as
  the logo** (a pure, seeded function `order → [dot center, size]`, shared by both, unit-testable), shown in the
  gallery at 0 / 0.25 / 0.5 / 0.75 / 1. No color parameter: ink tokens only.
- Delegate: none.
- Tests (`StudyFeatureTests`): #2 (both buttons), #3, #4 (tables incl. boundaries), #5 (`swipeEase` follows),
  #6 (`swipeEnded` in each band → `review` called with that rating, `swipeEase` nil, flow as 001), #7, #8/#9 (no
  state change when `canRate` is false: unrevealed, editing, reviewing), #12 (failure → offline, retry keeps the card
  revealed, no ring), #13.

## API / MCP changes
None. `POST /cards/{id}/review` already takes `again | hard | good | easy`; MCP `review_card` unchanged. The
continuous value stays on the device and is discarded after the release (backlog 22 covers keeping it).

## Accessibility identifiers
New: `study.swipeRing` (the dots; exists only during a drag; label "Rating", value = grade).
Kept: `study.rate.again` (now "Forgot"), `study.rate.good` (now "Got it"), `study.card`, `study.front`, `study.back`
(now also carry the four rating actions when `canRate`). Removed: `study.rate.hard`, `study.rate.easy`.

## Design notes (design-lead)
_To fill before implementation; design-critic reviews. Decide and write here, then copy the outcome into
`docs/design-system.md` (tokens, Components, Motion):_
- **Dot count** (proposal: 12–16, readable at 92 pt radius, not busy) and **dot size** (min 4 pt, so a
  scattered dot under a thumb still reads).
- **Ring radius**: the gesture scale is fixed by the spec at 0.25 x card width (92 pt). Decide whether the drawn ring
  matches it or is smaller (the value mapping doesn't change).
- **Noise model**: radial and tangential jitter amplitude at `v` = 0, size variation, maybe a few dots dropping out,
  and the curve from order to noise (linear or eased) so Hard and Got it look clearly different from the neutral
  state. Seeded and deterministic. It must come from the logo's dot primitive (round 5 route), so both use one
  generator and one set of rules.
- **Harmony rules (design-critic standards)**: the five arrangements (0 / 0.25 / 0.5 / 0.75 / 1) must read as
  distinct in grayscale at a glance. `v` = 1 must look calm and finished, not mechanical. `v` = 0 must look
  "lost", not broken or glitchy. Ink vs secondaryInk use (e.g. ordered dots in ink, stray dots in secondaryInk), and
  a hairline or none so the dots read on all three backgrounds over card text. No pink (the accent rule's one-pink
  limit and the counter's pink number stay as they are).
- **Appear/disappear**: proposal: dots gather from the touch-down point with `Theme.Motion.standard` plus fade, and
  opacity only with Reduce Motion. Near the screen edge the ring may be clipped; say whether that's acceptable (spec:
  yes, the value still clamps).
- Two-button row spacing (two items instead of four). No onboarding hint (proposal; backlog 21).

## Notes for QA
- Existing UI tests use `study.rate.hard` / `study.rate.easy` (StudyUITests, and RefreshUITests helpers that loop
  over four ratings): switch them to the two buttons, and test hard/easy through drags (#6).
- The "four rating buttons" checks in 001 #2, 006 #3 and 010 now mean "the two buttons".
- Start drags at the card's center so the full scale stays on screen. Read the grade from
  `study.swipeRing`'s `value` in preview-held tests.
- #10 needs the stub's long-text card (as 010 #15).

## Out of scope
- Sending or storing the continuous value (backlog 22); any API or scheduling change.
- Velocity/flick commits, hysteresis at bin edges, a vertical dimension, an onboarding hint (backlog 21).
- Moving the ring away from a touch-down near the screen edge (the user starts nearer the middle).
- Color in the rating feedback, and a text label for the grade on screen (the user asked for shape only; VoiceOver
  actions and haptics cover access).
- Dragging an unrevealed card (to reveal or skip), undo (backlog 10), showing the next interval per grade.
