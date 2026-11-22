# 018 — Auto-refresh: no pull-to-refresh, the app stays current by itself

Status: ready
Owners: ios-engineer
Depends on: 006 (refresh rule, foreground reload), 001 (Study phases), 002/009a (Deck)
Supersedes: the pull-to-refresh half of [006](006-refresh.md) (its AC #1 pull, #2, #7, #8 pull, #11, #12 pull).
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg (study),
04-list-dark.jpg (deck). No new visuals: this spec removes a control and a bounce.

## Goal
The user never refreshes. Study and Deck no longer have pull-to-refresh, and the Study screen no longer moves
under a vertical drag when nothing needs scrolling. Instead the app reloads by itself when it matters: coming
back to the app, the moment the next card becomes due, and every 30 s while there is nothing to study (to
catch cards an agent adds over MCP). User request 2026-11-22: "Having to refresh is bad design."

## User stories
- As the user, I never pull to refresh: dragging the study screen does nothing unless the card is long enough
  to scroll.
- As the user, I leave the app open on "All caught up" and the next card shows by itself when it is due.
- As the user, I ask my agent to add cards while the app shows "All caught up" (or "No cards yet"), and they
  appear within about 30 s without touching the phone.
- As the user, the card I am looking at never changes under me because of a background reload.
- As the user, when the API comes back after "Can't reach your deck", the app recovers by itself.

## Triggers (all quiet: no spinner, no `.loading` phase, current content stays until the response replaces it)
| Trigger | Study | Deck |
|---|---|---|
| Scene becomes `.active` (launch, return from Home/app switcher, Control Center) | reload (006 rule, kept) | reload with the current query (006, kept) |
| `next_due` from `/stats` is reached while the app is open | reload | — |
| Every 30 s while Study is caught up, empty ("No cards yet") or offline | reload | — |
| Last card of the queue rated / reported, Deck or Settings closed, server changed | reload (existing) | — |
| Deck's own add/edit/delete | — | reload (existing) |

**One timer, not polling in general.** When Study enters `.caughtUp`, `.empty` or `.offline` it arms a single
cancellable sleep of `clamp(nextDue − now, 1 s … 30 s)` (just 30 s when `nextDue` is nil or the phase is
empty/offline), then does a quiet reload. The reload lands back in one of those phases (re-arming) or in
`.studying` (no timer). So the `next_due` moment is hit exactly when it is under 30 s away, and otherwise
the 30 s check gets there within 30 s anyway. The 1 s floor stops a tight loop if the device clock runs ahead
of the server's (the reload would come back empty with the same `next_due`).

**Why 30 s.** The case that matters is the user watching the phone while an agent adds cards on another
device; 30 s keeps that under a "did it work?" wait. The cost is two tiny requests (`GET /cards/due` returning
`[]`, then `GET /stats`) per 30 s, only while the app is in the foreground with nothing to study, and the
screen auto-locks within minutes. No timer while studying (the queue is in hand; new cards are picked up when
it runs out) or in `.notSetUp` / `.unauthorized` (only Settings can fix those, and closing Settings reloads).

**No API change.** Checked for a cheaper change signal: when nothing is due, `GET /cards/due?limit=100` already
answers `[]`, the smallest possible payload, and that empty answer is exactly the "nothing new" signal. An
ETag / `updated_at` max on `/stats` would save nothing for Study. It would only help a Deck poll (500 notes per
call), which this spec leaves out (backlog #39).

**Never yank the visible card.** A quiet reload while studying keeps the card on screen when the server still
serves it: if the current first card's id is anywhere in the response, it stays first (and stays revealed);
the rest of the queue follows in the server's order, so new cards join behind it. Only if the current card is
gone from the response (reviewed, deleted or reported elsewhere) does the new first card show, unrevealed (as
in 006). The existing guards stay: no reload while a rating/report is in flight or while editing inline (006 #4,
010, 015).

**Background.** `scenePhaseChanged(.background)` cancels the timer (iOS suspends the app anyway); the
`.active` reload on return re-arms it. `.inactive` changes nothing.

## Acceptance criteria
"Stub" = `StubAPIServer` in the UI-test runner (006 notes). Unit tests use `TestClock` + a fixed
`@Dependency(\.date)`.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Study has no pull-to-refresh in any phase: a downward drag from `study.card` (short card), `study.message` (caught up, offline, no cards) makes no `GET /cards/due` request and shows no refresh control | UI (stub, light) |
| 2 | Study, short card (fits): a downward drag on `study.card` doesn't move `study.front` (frame unchanged within 1 pt after the drag), same for `study.message` in caught up. A card too long to fit still scrolls vertically (011 #10 / `testRatings_longCardScrollAndPull` scroll half) | UI (stub, light) |
| 3 | Deck has no pull-to-refresh: a downward drag on `deck.row.<id>` makes no `GET /notes` request and shows no refresh control. A short list doesn't bounce (`.scrollBounceBehavior(.basedOnSize)`) | UI (stub, light) |
| 4 | Study, caught up with `nextDue` = now + 10 s: after 10 s on the `TestClock`, one `dueCards` call is made, with no `.loading` phase; if it returns a card, phase is `.studying` with that card unrevealed. Nothing is fetched before 10 s | unit |
| 5 | Study, caught up with `nextDue` nil or more than 30 s away, or `.empty`: a quiet reload runs every 30 s; while still caught up/empty each response re-arms one timer (advancing 90 s gives exactly 3 `dueCards` calls) | unit |
| 6 | Study, caught up with `nextDue` in the past (device clock ahead): the timer waits 1 s, not 0 | unit |
| 7 | Study, offline: every 30 s a quiet retry runs; the phase stays `.offline` (no `.loading`) until a response succeeds, then becomes `.studying` / `.caughtUp` / `.empty`. `study.retry` still works and still shows `.loading` (unchanged) | unit |
| 8 | Study, `.studying`, `.loading`, `.notSetUp`, `.unauthorized`: no timer runs (advancing the clock 5 min makes no call). Entering `.studying` from a caught-up reload cancels the timer | unit |
| 9 | `scenePhaseChanged(.background)` cancels the timer (advancing 5 min makes no call); `.active` reloads (006) and, once caught up again, re-arms it. `.inactive` leaves the timer running | unit |
| 10 | Quiet reload while studying (foreground, `deckChanged`): if the current first card's id is in the response at any position, it stays first and keeps `isRevealed`; the other cards follow in response order. If it is absent, the response's first card shows unrevealed | unit |
| 11 | Guards unchanged: no reload (timer or foreground) while `isReviewing`, `editing != nil` or `isSavingEdit`. A timer firing then is dropped and re-armed from the phase the pending response lands in | unit |
| 12 | End to end, no interaction: stub caught up with one card due 8 s after launch (`study.nextDue` shown) → within 15 s `study.front` shows that card, unrevealed, "1 to review", without any tap or drag | UI (stub, light + dark) |

Not UI-tested (would need a 30 s wait in CI): the agent-add check (#5) and offline recovery (#7). The
`.active` reload stays covered by `testStudy_foregroundReload` (006 #3, #5).

## Screens & states
No visible change at rest. What changes:
- **Study**: no `.refreshable`. The message states (`loading`, caught up, empty, offline, not set up,
  unauthorized) keep their scroll view (so large text can still scroll) but with
  `.scrollBounceBehavior(.basedOnSize)`: rename `pullable` to e.g. `centeredMessage` and drop the pull wording
  in its doc comment. The card's `ScrollView` gets `.scrollBounceBehavior(.basedOnSize)` (006 had removed it so
  short cards could be pulled). Long cards scroll as before.
- **Deck**: no `.refreshable` on the `List`; `.scrollBounceBehavior(.basedOnSize)` on it.
- Background reloads show nothing: the counter (`study.remaining`) and content just update.

Screenshots (QA): `study-auto-due` (light + dark, #12: the card shown after `next_due`, no interaction),
`study-no-pull` (light, #1/#2: after the drag, screen unchanged), `deck-no-pull` (light, #3).

## TCA shape (iOS)
No new module, no `AppFeature` change.

**`StudyFeature`**
- State: unchanged.
- Actions: remove `pulledToRefresh`. Add `autoRefreshFired` (internal: the timer elapsed).
- Dependencies: add `@Dependency(\.date) var now` (for `nextDue − now`); `continuousClock` already there.
- `CancelID`: add `.autoRefresh`.
- `static let autoRefreshInterval: Duration = .seconds(30)`.
- Helper `armAutoRefresh(_ state: State) -> Effect<Action>`: for `.caughtUp(nextDue)` / `.empty` / `.offline`
  returns `.run { try await clock.sleep(for: delay); await send(.autoRefreshFired) }
  .cancellable(id: CancelID.autoRefresh, cancelInFlight: true)`; any other phase returns
  `.cancel(id: CancelID.autoRefresh)`. Call it after every assignment of `state.phase` in `statsResponse` and the
  failure branch of `cardsResponse`/`statsResponse`/`reviewResponse`, and when `cardsResponse` sets `.studying`.
  `delay` is 30 s for nil/empty/offline, else `min(max(nextDue − now, 1 s), 30 s)`.
- `.autoRefreshFired`, `.scenePhaseChanged(.active)`: same guard as today's `.scenePhaseChanged(.active)`, then
  `fetchDueCards` (quiet). If the guard drops it, nothing else is needed: the pending review/edit response lands
  in a phase that re-arms (or `.studying`).
- `.scenePhaseChanged(.background)` → `.cancel(id: CancelID.autoRefresh)`; `.inactive` → `.none`.
- `cardsResponse(.success)`: the merge rule above (#10) replaces the "first id differs → reset" check:
  if the current first id is in the new list, move it to the front before assigning; reset `isRevealed` /
  `swipeEase` only if the first id still differs after that.
- View: delete `.refreshable`; bounce changes above.

**`DeckFeature`**
- Remove `pulledToRefresh` (keep `onAppear`, `scenePhaseChanged(.active)`, `retryButtonTapped`). View: delete
  `.refreshable`, add `.scrollBounceBehavior(.basedOnSize)`.

**Unit tests**: one test per criterion #4–#11 in `StudyFeatureTests` (`TestClock`, `withDependencies { $0.date
= .constant(…) }`). Existing tests that send `.pulledToRefresh` switch to `.scenePhaseChanged(.active)` (same
path) or go away when they duplicate one: `StudyFeatureTests` lines ~312–485, ~829–871; `StudyReportTests`
~248, ~431; `DeckFeatureTests` ~368, ~503. Tests that end in `.caughtUp`/`.empty`/`.offline` now also start the
timer: end them with `await store.send(.scenePhaseChanged(.background))`, which cancels it (one convention
everywhere).

## Tests that become obsolete or change
UI (`ios/LaCarteUITests`, owned by qa-validator):
- `RefreshUITests` (CI group `settings-refresh-misc`): delete `testStudy_pullToRefreshWhileStudying`,
  `testStudy_pullFromEmptyCardArea`, `testDeck_pullToRefresh`, `testStudy_refreshSpinnerForest`,
  `testStudy_pullToRefresh_liveAPI`. Keep `testStudy_foregroundReload` (006 #3, #5, still true). Add #1, #2,
  #3, #12 here (rename the class doc to "Spec 006 + 018"). The group name can stay.
- `RatingsUITests.testRatings_longCardScrollAndPull`: keep the scroll half, drop the pull half (rename
  `…LongCardScroll`).
- `ReportUITests.testReport_heldAfterRefresh` (015b #10): trigger with `backgroundAndReactivate(app)` instead
  of the pull.
- `Support.swift`: `pullToRefresh` stays as the drag helper for #1–#3 (rename `dragDown` if it reads better);
  `pullToRefreshCapturing` can go.
- `scripts/e2e.sh`: remove `RefreshUITests/testStudy_pullToRefresh_liveAPI` from its `-only-testing` list and
  the comment at line ~36 (qa-validator owns the script).

Spec AC made obsolete (mark them in the specs, done in this change): 006 #1 (pull part), #2, #7, #8 (pull
part), #11, #12; 008 #10 (pull part; foreground and Settings close still reload); 015 #10 (pull wording;
foreground reload keeps it true); 009c #1 ("inside the pull-to-refresh scroll view": now a non-bouncing
scroll view).

## API / MCP changes
None (see "No API change" above). Uses `GET /cards/due`, `GET /stats`, `GET /notes`.

## Accessibility identifiers
None new. Drags in #1–#3 start on `study.card`, `study.message`, `deck.row.<id>`; #12 reads `study.nextDue`,
`study.front`, `study.remaining`.

## Notes for QA
- #1/#3: count requests on the stub before and after the drag (as `testRatings_longCardScrollAndPull` does),
  wait 3 s, assert no new `/cards/due` or `/notes` request, and no `XCUIApplication().activityIndicators`.
- #12: the stub's `next_due` must be relative to the real time at launch (`Date().addingTimeInterval(8)`), not
  the fixed 2026-01-01 base. Its `/cards/due` must start serving the card once that time passes.
- Docs/marketing: `docs/marketing/shot-list.md` (shot 4) and `docs/marketing/agent-video.md` (shot 4) script a
  pull to refresh. Marketing should re-cut them to wait for the auto-refresh (≤ 30 s, can be trimmed in the
  edit) or background/foreground the app.

## Out of scope
- Live update of the Deck list while it stays open (needs a cheap change token, e.g. `max(updated_at)` +
  count on `/stats`, to avoid fetching 500 notes every 30 s): backlog #39.
- Push / server-sent events / background app refresh.
- Network reachability monitoring (`NWPathMonitor`): the 30 s offline retry is good enough.
- Showing new cards in the counter while studying (the queue is refetched when it runs out or on foreground).
- Any "updated" indicator.
