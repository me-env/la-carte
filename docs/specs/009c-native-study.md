# 009c — Native polish: Study screen

Status: ready (starts after 011 is merged)
Owners: ios-engineer
Split from: 009 (native polish, design-lead draft; criteria #7 study part, #8 study part, #10, #11, #14 counter).
Depends on: **010 and 011 merged** (same files: `StudyFeature.swift`, `StudyView.swift`). 010 already adds the
edit haptics and hides the counter while editing; 011 adds the rating gesture. Keep both behaviors.
Design reference: docs/design/reference/01-editor-dark.jpg, 02-editor-light.jpg (one thing centered).

**Parallelism.** Touches only `StudyFeature/**` and `StudyFeatureTests`. Do not start while 010 or 011 is open.
Can run next to anything outside Study (009a, 009b, 016, 007 follow-ups).

## Goal
Study gets the system's empty states, a counter that ticks down, a brand loading mark on slow networks, and a
light tap on reveal and rating. The card face and caught-up screen stay custom.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Offline, not set up and token rejected use `ContentUnavailableView` (symbols `wifi.slash`, `link`, `key`), inside the pull-to-refresh scroll view (006). Ids stay: title `study.message`, description `study.detail`, buttons `study.retry` / `study.openSettings` (plain text buttons, ink) | UI (light, dark) |
| 2 | Caught-up stays custom (card-face type, `study.message` + `study.nextDue`) | UI (unchanged) |
| 3 | `study.remaining` is one `Text`: the number in `Theme.accent`, " to review" in `secondaryInk`, with `.contentTransition(.numericText(countsDown: true))` animated with `Theme.Motion.standard` when a rating removes a card. Still hidden while editing (010) | review + UI screenshot |
| 4 | When loading lasts more than 0.5 s, `LaCarteLoadingMark` (64 pt, centered, `study.loading`) shows; a load that finishes sooner never shows it. Reduce Motion gives the mark's built-in opacity pulse | unit (TestClock) + UI (stub delays `GET /cards/due` 2 s) |
| 5 | Haptics: `.selection` on reveal; `.success` after a review response succeeds (button or 011 drag); `.error` when a load ends offline/unauthorized. 010's edit haptics and 011's bin ticks are unchanged. Nothing else vibrates | unit (trigger state) + device check |
| 6 | Every animation added here has a Reduce Motion variant; AX5 doesn't clip; every interactive element keeps an id | UI (AX5, Reduce Motion launch arg) |

## Screens & states
Screenshots (light + dark): `study-offline`, `study-not-set-up`, `study-loading`, `study-counter` (light, pink number).

## TCA shape (iOS)
- State: `var isLoadingVisible = false`; `var reviewedCount = 0` (incremented on a successful review response;
  `.success` haptic trigger).
- Load start runs `clock.sleep(for: .seconds(0.5))` then sends `loadingDelayElapsed` (sets `isLoadingVisible`),
  cancellable with id `CancelID.loadingMark`; any load response cancels it and clears `isLoadingVisible`.
- Reveal haptic: `.sensoryFeedback(.selection, trigger: store.isRevealed) { _, new in new }`.
- Error haptic: same rule as 009a on `phase`.
- Tests: mark shows after 0.5 s and not before; fast load never shows it; `reviewedCount` increments on success only.

## API / MCP changes
None.

## Accessibility identifiers
New: `study.loading`. All others unchanged.

## Out of scope
Zoom transition Study → Deck (audit P3); streak on caught-up (backlog #15); deck/editor/settings (009a, 009b).
