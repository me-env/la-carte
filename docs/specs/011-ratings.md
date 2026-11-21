# 011 — Ratings: two buttons, four-way swipe

Status: ready
Owners: ios-engineer (design-lead fills "Design notes" first). No API work.
Depends on: 001 (study), 006 (refresh rule), **010 (inline edit) merged first** (same view, uses `editing`). Independent
of 009 (draft); if 009 lands, its haptics (#8) apply to both rating paths unchanged.
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg (one thing centered, quiet text
buttons at the bottom; nothing new on screen at rest).

## Goal
Rating gets simpler: two buttons, "Forgot" and "Got it", cover most reviews. For finer answers, the user swipes the
revealed card: the farther the swipe, the stronger the answer (left = Hard, then Forgot; right = Got it, then Easy).
The API's four ratings stay as they are; only the way the app asks for them changes.

## User stories
- As the user, I reveal a card and tap "Forgot" or "Got it".
- As the user, I swipe the revealed card right to say "Got it", or farther right to say "Easy"; left for "Hard",
  farther left for "Forgot". A label under the card tells me which answer I'll give if I let go now.
- As the user, I let go before the first step and nothing happens: the card comes back.
- As the user with VoiceOver, I pick any of the four answers from the card's actions.

## Interaction rules (decided)
- **Buttons**: "Forgot" (left, sends `again`) and "Got it" (right, sends `good`). Hard and Easy have no button.
- **One horizontal axis, distance = confidence.** `f = translation.x / cardWidth`, where `cardWidth` is the width of
  `study.card` (370 pt on iPhone 17 Pro: 402 minus 2 x 16 margin).

  | `f` | Rating sent on release | Label (`study.swipeLabel`) |
  |---|---|---|
  | `f <= -0.45` | `again` | Forgot |
  | `-0.45 < f <= -0.2` | `hard` | Hard |
  | `-0.2 < f < 0.2` | nothing (card comes back) | none (rating row shows) |
  | `0.2 <= f < 0.45` | `good` | Got it |
  | `f >= 0.45` | `easy` | Easy |

  Why these values: **0.2** (~74 pt) is well past an accidental nudge or a sloppy tap (system pan slop is ~10 pt) and
  is about the distance of a deliberate list swipe action. **0.45** (~167 pt) must be reachable in one thumb sweep
  that starts at the center of the screen (201 pt from center to edge on a 402 pt screen, so ~34 pt to spare);
  0.6 or more would force the user to start from the opposite edge. The gap between them (~93 pt) is wide enough to
  stop in the first zone on purpose. Thresholds are fractions, so they scale with the device and the test can use
  normalized coordinates.
- **Distance only, no velocity.** A fast flick that ends under 0.2 rates nothing. Predictable beats clever.
- **Release commits** exactly like tapping a button: the same review request, the same in-flight rule
  (`isReviewing`), the same next-card / caught-up / offline flow from 001. While the review is in flight the label
  stays and the card stays off to the side; the next card appears instantly (001: moving on never animates).
- **The axis locks at the start of the gesture.** A gesture whose first movement is mostly horizontal
  (`|dx| > |dy|`) is a swipe; anything else is the card's vertical scroll or pull-to-refresh, and the card never
  moves sideways during it. So long cards still scroll (001), pull-to-refresh still works on the card (006 #7).
- **Swipe is possible exactly when the rating buttons can be tapped**: `phase == .studying && isRevealed &&
  editing == nil && !isReviewing` (State's `canRate`). So: not before reveal (a sideways drag on an unrevealed card
  does nothing and does not reveal), not while editing (010), not while a review is in flight. Like the buttons
  (010: "rating is allowed while a save is in flight"), swipe stays allowed while an edit save is in flight; one
  rule for both ways of rating.
- **Taps and double-taps are untouched**: a pan needs movement, so tap-to-reveal (001 #2) and double-tap-to-edit
  (010 #2) work as before.
- **Feedback**: the card follows the finger 1:1 and tilts slightly with the distance. A light haptic tick each time
  the label changes to a rating (none → Got it, Got it → Easy, Easy → Got it, ...); no tick when it goes back to none.
- **Reduce Motion**: no tilt; on commit the card fades out in place instead of sliding off; on cancel it jumps back
  to the center. The card still follows the finger (direct manipulation), and label and haptics are unchanged.
- **VoiceOver**: all four ratings are accessibility actions ("Forgot", "Hard", "Got it", "Easy") on the card's
  text elements `study.front` and `study.back` (the card's `ScrollView` is a container VoiceOver never focuses, so
  the actions go where focus lands, next to 010's "Edit"). Present only when `canRate`. The two buttons remain.

## Acceptance criteria
Mock deck = `LA_CARTE_API=mock` (`serendipity`, `la carte`, `ephemeral`). Stub = `StubAPIServer` (records request
bodies, so a test can read the rating sent). Drags in UI tests: on `study.card`,
`coordinate(withNormalizedOffset: (0.5, 0.5)).press(forDuration: 0.05, thenDragTo: coordinate(withNormalizedOffset: (0.5 + f, 0.5)))`;
normalized x is a fraction of the card's width, the same unit as `f`. Use `f` = 0.32 / 0.48 / -0.32 / -0.48 for
the four zones and 0.1 for "under the first threshold".

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | On a revealed card the bottom row shows exactly two buttons, `study.rate.again` "Forgot" on the left and `study.rate.good` "Got it" on the right; `study.rate.hard` and `study.rate.easy` do not exist. Before reveal neither exists (001 #3 unchanged) | UI (light, dark, forest) |
| 2 | Tapping "Forgot" sends `POST /cards/{id}/review` with `again`, "Got it" with `good`; the rest of 001 #4 holds (buttons disabled in flight, next card unrevealed, "2 to review") | unit + UI (stub body) |
| 3 | `StudyFeature.rating(forSwipe:)` maps `f` per the table above, boundaries included: -0.5 → again, -0.45 → again, -0.44 → hard, -0.2 → hard, -0.19 → nil, 0 → nil, 0.19 → nil, 0.2 → good, 0.44 → good, 0.45 → easy, 0.8 → easy | unit |
| 4 | While a revealed card is dragged, `swipeChanged(f)` sets `swipeRating` to the zone's rating; `study.swipeLabel` shows that rating's label ("Got it", "Easy", "Hard", "Forgot") in place of the rating row; dragging back under 0.2 removes the label and the two buttons show again | unit + UI screenshots (see "Screens") |
| 5 | Releasing in a zone sends the review with that rating, exactly as #2: right 0.32 → `good`, right 0.48 → `easy`, left 0.32 → `hard`, left 0.48 → `again`. After each, the next card's front shows unrevealed and `study.remaining` decrements | unit + UI (stub body, one card per zone) |
| 6 | Releasing under the first threshold (f = 0.1) sends nothing; the card is back in the center, still revealed, both buttons visible and enabled | unit + UI |
| 7 | A horizontal drag (f = 0.48) on an **unrevealed** card sends nothing, does not reveal it, and shows no label; `swipeChanged` / `swipeEnded` change no state when `canRate` is false | unit + UI |
| 8 | While editing (010: `study.backField` focused), a horizontal drag on the card sends no review and shows no label; while a review is in flight, `swipeChanged` / `swipeEnded` change no state | unit + UI (editing case) |
| 9 | Long card (stub, ~200-character back, revealed): a vertical drag scrolls the back into view, shows no label and sends nothing; a pull-down on the revealed card refreshes (006 #7: the card stays revealed) and sends no review | UI (stub) |
| 10 | Double-tapping `study.back` on a revealed card still opens `study.backField` (010 #3); a single tap on the unrevealed card still reveals it (001 #2) | UI (regression) |
| 11 | After a swipe whose review fails, the screen shows "Can't reach your deck" (001 #7); retry brings back the same card, revealed, centered, with the two buttons and no label (`swipeRating == nil`) | unit + UI (stub review 500) |
| 12 | A due-cards response whose first card differs from the current one (refresh mid-drag) clears `swipeRating` along with `isRevealed`; a response with the same first card keeps it | unit |
| 13 | A light haptic plays each time `swipeRating` changes to a non-nil value, none when it becomes nil | review + device check |
| 14 | Motion: the card follows the finger 1:1, tilts proportionally (`Design notes` give the angle), slides off in the swipe direction on commit and stays off while the review is in flight, returns to center with `Theme.Motion.standard` on cancel. Nothing bounces | screenshot review + device check |
| 15 | Reduce Motion: no tilt, commit fades the card out in place, label and haptic unchanged | review + device check (no Reduce Motion launch switch exists for UI tests) |
| 16 | VoiceOver: on a revealed card, `study.front` and `study.back` expose actions "Forgot", "Hard", "Got it", "Easy" (plus 010's "Edit"); each sends `ratingTapped` with `again` / `hard` / `good` / `easy`. None before reveal, while editing, or while a review is in flight | review + VoiceOver device check |
| 17 | Dynamic Type accessibility XL: the two buttons and every label fit on one line in the bottom slot, nothing clipped | UI (light) |
| 18 | Live API (`scripts/e2e.sh`): in `testStudy_revealRateToCaughtUp_liveAPI`, the first card is rated with a right swipe (f = 0.32) and the second with the "Got it" button; the test still ends on "All caught up" | UI (`_liveAPI`) |

## Screens & states
No new screen. At rest nothing changes except the row: "Forgot   Got it" (same quiet `.body` ink text buttons as
001, centered, the row keeps its reserved height so the front never moves on reveal). While dragging past a
threshold, the bottom slot shows `study.swipeLabel` instead of the row (same slot, no layout shift). It stays there
during the review in flight after a commit.

Screenshots (QA, `<screen>-<state>`), light + dark + forest unless noted:
`study-revealed` (two buttons), `study-swipe-good`, `study-swipe-easy`, `study-swipe-hard`, `study-swipe-again`
(card held in each zone, label visible, card offset and tilted), `study-revealed-xl` (light, AX XL, #17).

**How QA holds a swipe for a screenshot**: XCUITest's drag calls block until the finger lifts, so the held state is
reached with a DEBUG-only launch argument `-studySwipePreview <f>` (UserDefaults argument domain, like `-theme`).
When set, `StudyView` behaves as if the finger were held at `f` on the revealed card: same offset, tilt, and it
sends `swipeChanged(f)` once when `canRate` becomes true, so the label is the real one. No release ever happens.
Use `f` = 0.32 / 0.48 / -0.32 / -0.48.

## TCA shape (iOS)
No new module, no new dependency. `StudyFeature` + `StudyView` only.

- State (new):
  ```swift
  var swipeRating: Rating?          // zone the held swipe points to, or the rating it committed (until the response)
  var canRate: Bool {               // buttons tappable == swipe possible == VoiceOver actions present
    phase == .studying && isRevealed && editing == nil && !isReviewing
  }
  ```
- Mapping (reducer side, pure, unit-tested by #3):
  ```swift
  static let swipeThresholds = (rate: 0.2, strong: 0.45)   // fractions of the card's width
  static func rating(forSwipe fraction: Double) -> Rating?
  ```
- Actions (new): `swipeChanged(fraction: Double)`, `swipeEnded(fraction: Double)`. The view sends raw fractions; it
  never decides a rating. VoiceOver actions send the existing `ratingTapped(Rating)`.
- Logic:
  - `swipeChanged(f)`: `guard state.canRate`; compute the rating; assign `swipeRating` **only if it differs** (the
    action arrives every frame; an unchanged value must not re-render the view).
  - `swipeEnded(f)`: `guard state.canRate`; `swipeRating = rating(forSwipe: f)`; nil → `.none`; else the same path
    as `ratingTapped`. Move `ratingTapped`'s body (guard, `isReviewing = true`, 010's `editFailed = false`, cancel
    the load, run `review`) into a private helper `review(_ rating:, state:)` used by both (convention: shared logic
    in a helper, not an internal action).
  - `reviewResponse` (success and failure): `swipeRating = nil`.
  - `cardsResponse(.success)`: where it resets `isRevealed` (first id changed), also `swipeRating = nil`.
  - The `swipeChanged(0)` that follows a lift (gesture state resetting) arrives while `isReviewing` and is ignored by
    the guard, so the label stays during the request; after a cancelled gesture it clears the label. No extra case.
- View (`StudyView`):
  - A horizontal pan on `study.card`, enabled only when `store.canRate`, that begins only when the first movement is
    mostly horizontal. Recommended: `UIGestureRecognizerRepresentable` wrapping a `UIPanGestureRecognizer` whose
    `shouldBegin` checks `|velocity.x| > |velocity.y|`, so the `ScrollView` pan and the refresh control keep vertical
    gestures. A SwiftUI `DragGesture` is fine if #9 passes on device and in UI tests.
  - Reports `translation.x / cardWidth` (`onGeometryChange` for the width) as `swipeChanged` on change and
    `swipeEnded` on end; a cancelled pan sends `swipeChanged(0)`.
  - Presentation state (offset, commit slide) may live in `@State` / `@GestureState`: it is visual only. The commit
    slide reads `store.isReviewing && store.swipeRating != nil` and the rating's side (again/hard left, good/easy
    right); it resets when the current card id or `phase` changes.
  - `.sensoryFeedback(.impact(weight: .light), trigger: store.swipeRating) { _, new in new != nil }`.
  - `@Environment(\.accessibilityReduceMotion)` for #15.
  - Bottom slot: `swipeRating != nil` → `study.swipeLabel`; else revealed and not editing → the two buttons
    (`.disabled(store.isReviewing)` as today); else `study.reveal` / empty per 001 / 010.
  - Copy lives with the view: `again` "Forgot", `hard` "Hard", `good` "Got it", `easy` "Easy" (one function used by
    the buttons, the label and the VoiceOver actions).
  - `-studySwipePreview` handling under `#if DEBUG` only (see "Screens").
- Delegate: none.
- Tests (`StudyFeatureTests`): #2 (both buttons' ratings), #3 (table incl. boundaries), #4 (state changes, no
  mutation when unchanged), #5 (`swipeEnded` in each zone → `review` called with that rating, flow as 001), #6,
  #7/#8 (no state change when `canRate` is false: unrevealed, editing, reviewing), #11 (failure clears
  `swipeRating`; retry keeps the card revealed), #12, and "`swipeChanged(0)` during a review keeps the label".

## API / MCP changes
None. `POST /cards/{id}/review` already takes `again | hard | good | easy`; MCP `review_card` unchanged.

## Accessibility identifiers
New: `study.swipeLabel`. Kept: `study.rate.again` (now "Forgot"), `study.rate.good` (now "Got it"), `study.card`,
`study.front`, `study.back` (now also carry the four rating actions when `canRate`). Removed: `study.rate.hard`,
`study.rate.easy`.

## Design notes (design-lead)
_To fill before implementation. Decide and write here:_
- Tilt: max angle (proposal: proportional, ±8° at |f| = 0.5, clamped), anchor point (proposal: bottom center).
- What moves: the front + back together (there is no card chrome in Vyst); whether the text fades a little with
  distance.
- `study.swipeLabel`: font/color (proposal: `.body`, `ink`, same as the buttons it replaces), whether "Forgot" and
  "Easy" differ from "Hard" / "Got it" (weight?), transition between labels (proposal: none, or a crossfade with
  `Theme.Motion.standard`). No pink, no red/green (design-system accent rule).
- Commit slide distance/duration and Reduce Motion fade (proposal: `Theme.Motion.standard`).
- Two-button row spacing (now two items instead of four) and whether a subtle hint teaches the swipe (proposal: no
  hint; the buttons cover the common case).
- Update `docs/design-system.md` (Motion / Components) with anything decided here.

## Notes for QA
- Existing UI tests use `study.rate.hard` / `study.rate.easy` (StudyUITests, RefreshUITests helpers that loop over
  four ratings): switch them to the two buttons, and test hard/easy through swipes (#5).
- The rating row's "four buttons" checks in 001 #2, 006 #3 and 010 now mean "the two buttons".
- Drags must start at the card's center; the normalized offsets above stay on screen (0.02 to 0.98 of the card).
- #9 needs the stub's long-text card (as 010 #15).

## Out of scope
- Velocity-based commit (flick), hysteresis at the thresholds, a swipe hint or onboarding.
- Swiping an unrevealed card (to reveal or to skip), vertical swipes, undo (backlog 10).
- Showing the next interval per rating while swiping (001 out of scope, still).
- Any API or scheduling change.
