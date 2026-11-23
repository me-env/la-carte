# 021 — New cards never held; the daily milestone ladder

Status: ready
Owners: api-engineer (server, first), ios-engineer (Study counter + ladder popover), design-lead (design-system.md lines)
Depends on: 014a (notes, sibling burying), 015a (reports), 018 (auto-refresh), 022 (queue order), all merged. 024
step 1 (merged) already added `new_today`, `milestone` and `due_new` to `/stats`. Backlog #43.
Design reference: `docs/design/renders/021/milestone-ladder.png` (design-lead's real-view renders, approved by the
user 2026-11-23). Renders can't draw Liquid Glass: the counter's capsule and the popover's glass come from the system.

**Revision 3, 2026-11-23 (milestone ladder, approved by the user).** v2's single "Milestone K" counter, chevron,
marks, explanation lines and "Milestone K reached" notice are gone. The day is now a short ladder of steps: **At
risk** (only on heavy days), **Reviews**, then **15 new**, **30 new**, … The ladder is **display only**: it never
changes what is served or in which order. v1's hold (removed by the hotfix) stays gone.

## Goal
Every new card can be studied right away, however many an agent adds, and every session still feels finite. The
top bar counts down to the next step of a small ladder ("8 at risk", "22 to review", "6 new"); tapping it shows the
ladder; finishing a step says so in one quiet line. Nothing blocks, nothing nags, and nothing says reviews are a
daily must (the streak needs one review a day, spec 024).

## User stories
- As the user back from a break, the counter says "8 at risk": I clear the cards I'm about to forget first, see
  "At risk done", and can stop there.
- As the user on a normal day, the counter says "8 to review"; after it, "Reviews done", then "15 new" counts down.
- As the user, an agent adds 60 words and I learn all of them tonight if I want: "15 new done", "30 new done", ….
- As the user, I tap the counter and see the steps I finished (grey, checked) and the one I'm on, with a bar.
- As the user, I tell my agent "only 5 new cards a day" and the new-card steps become 5, 10, 15, ….

## Decisions
1. **No hold** (unchanged from v2). Every never-reviewed, non-held (spec 015) card is servable as soon as it's
   added. Sibling burying stays as in spec 014, for new cards too. No one-new-card-per-note rule.
2. **Queue order is spec 022's, untouched by the ladder**: (re)learning cards by `due`, then review cards lowest
   retrievability first, then new cards oldest first (`_card_order`). No cap.
3. **Milestone size M = the stored setting** (unchanged from v2). Column `settings.new_cards_per_day`, no migration.
   Default 15, valid 1–200; a stored 0 reads as 15. MCP tool renamed `new_card_milestone`, no alias.
4. **"Today" = the local calendar day in `tz`**, as for `reviewed_today` and `streak`. `start_of_day` = local
   midnight of today in `tz`.
5. **The ladder's steps, in order.** Each step has a `done` and a `total`; it is complete when `done == total`.
   1. **At risk** (shown only when `at_risk_total > 0`). The **snapshot** S of the day = every card that, at
      `start_of_day`, had already been reviewed at least once (it has a memory state) and whose FSRS retrievability
      at `start_of_day` was below **0.8**. With the default desired retention 0.9 a card is at 0.9 on its due date,
      so these are overdue cards. S is fixed for the day: a card that falls below 0.8 at 15:00 isn't added, and a
      card in S stays in S after it's reviewed.
      - `at_risk_done` = cards of S reviewed at least once today (any rating; a card failed today is done).
      - `at_risk_total` = `at_risk_done` + cards of S not reviewed today and not held by an open report (015).
        A deleted card that wasn't reviewed today drops out.
      - **Threshold**: when that sum is below **10**, the server returns `at_risk_total = 0` and `at_risk_done = 0`
        and the step doesn't exist today. Constants `AT_RISK_RECALL = 0.8`, `AT_RISK_MIN = 10` in `deck.py`.
      - How the server knows a reviewed card's state at `start_of_day`: each `ReviewLog` row now stores the card's
        memory state just before that review (`stability_before`, `last_review_before`, null when the card was
        new). For a card reviewed today, its first review today gives its state at `start_of_day` (it was last
        reviewed before today). For a card not reviewed today, its current fields are its state at `start_of_day`.
        Retrievability uses `_scheduler.get_card_retrievability` as in spec 022 (no copied formula).
      - Edge, accepted: a card of S buried by a sibling (spec 014, at most 6 h) keeps the step open until it's served.
   2. **Reviews** (shown when `reviews_total > 0`): every card that was already started before today.
      - `reviews_done` = distinct cards reviewed today whose first review ever was before today
        (= `reviewed_today − new_today`).
      - `reviews_total` = `reviews_done` + cards in the servable queue now whose `last_review` is before
        `start_of_day`. So a card failed today, or a new card learned today coming back for its learning step, is
        served as usual but doesn't reopen the step; a review that falls due at 15:00 adds 1 to the total once due.
      - Cards of S count here too: "At risk" is the first part of "Reviews".
   3. **New-card steps** of M: "15 new", "30 new", "45 new", …, from `new_today` (cards first reviewed today),
      `milestone` (M) and `due_new` (new cards servable now). Step k is complete when `new_today ≥ k·M`.
6. **The server reports, the app arranges.** `/stats` gains four counts (`at_risk_total`, `at_risk_done`,
   `reviews_total`, `reviews_done`); the new-card steps reuse `new_today`, `milestone`, `due_new`. The app turns
   them into rows, the counter and the notices with one pure function (`Ladder`, below). No step decides anything
   about the queue.
7. **The app refreshes the numbers after every rating.** Each queue load fetches `/cards/due?limit=100` and `/stats`
   concurrently and handles them as one response (this replaces today's sequential stats call when caught up).
   After each successful rating, the app fetches `/stats` once more (when the rating emptied the batch, the queue
   load that follows is that fetch). Only this post-rating stats response can show a step notice. A failed
   post-rating stats fetch changes nothing (no offline screen); the next load catches up.
8. **Step notice.** When the post-rating ladder completes a step that wasn't complete before the rating, the notice
   slot shows "{step label} done" ("At risk done", "Reviews done", "15 new done") for the usual notice duration,
   with the existing `.success` haptic. If one rating completes several steps, only the last step's notice shows.
   Never on launch, reload or foreground. No screen, no stop, no other text.
9. **The streak is not part of the ladder.** One review a day keeps it (spec 024). No string anywhere (app, MCP
   docstrings, `INSTRUCTIONS`) says reviews or steps must be done daily.
10. **REST**: `/stats` gains the four counts. No new endpoint, no in-app setting for M (backlog #44).

## The ladder (app, pure: `Ladder(stats:)`)
Inputs from `DeckStats`: `atRiskTotal`, `atRiskDone`, `reviewsTotal`, `reviewsDone`, `newToday`, `milestone` (M),
`dueNew` (W). Let `k = newToday / M` (integer division) and `T = (k + 1)·M`.

**Rows, in ladder order** (each row is done or not):
1. "At risk", when `atRiskTotal > 0`: fraction `atRiskDone/atRiskTotal`; done when equal.
2. "Reviews", when `reviewsTotal > 0`: fraction `reviewsDone/reviewsTotal`; done when equal.
3. The last finished new step, always done:
   - while new cards wait (W > 0) and k ≥ 1: "{k·M} new" (only the highest one: "45 new", not 15, 30, 45);
   - when none wait (W = 0) and `newToday > 0`: "{newToday} new" (the day's actual total, e.g. "7 new").
4. The next new step, when W > 0: "{T} new", fraction `newToday/T`, not done.

The **current row** is the first row that isn't done. The popover shows every row up to and including the current
one (rows after it, possible only when a review falls due late and reopens "Reviews", are hidden until it's done
again); with no current row, it shows every row.

**Counter** (the number is the only pink, decision unchanged from spec 009 rule 4):
- current "At risk": "{atRiskTotal − atRiskDone} at risk";
- current "Reviews": "{reviewsTotal − reviewsDone} to review";
- current new step: "{min(T − newToday, W)} new";
- no current row (every step done, yet the batch still has cards, e.g. today's learning steps), or no stats yet:
  today's counter, "{cards in the loaded batch} to review".

**Notice after a rating** (decision 8), comparing the ladder before (L0) and after (L1), first match wins:
1. `L1.newToday / M > L0.newToday / M` → "{(L1.newToday / M)·M} new done";
2. "Reviews" existed in L0 and was not done, and is done in L1 → "Reviews done";
3. "At risk" existed in L0 and was not done, and is done in L1 → "At risk done".

Mockup states as `Ladder` fixtures (they are also unit tests, AC 14):

| State | at risk | reviews | new_today / M / due_new | Counter | Popover rows |
|---|---|---|---|---|---|
| 1 backlog | 6/14 | 6/52 | 0 / 15 / 40 | "8 at risk" | At risk 6/14 |
| 2 reviews | 14/14 | 30/52 | 0 / 15 / 40 | "22 to review" | At risk ✓, Reviews 30/52 |
| 3 first new | 14/14 | 52/52 | 9 / 15 / 40 | "6 new" | At risk ✓, Reviews ✓, 15 new 9/15 |
| 4 many new | 14/14 | 52/52 | 49 / 15 / 30 | "11 new" | At risk ✓, Reviews ✓, 45 new ✓, 60 new 49/60 |
| 5 normal day | 0/0 | 12/20 | 0 / 15 / 0 | "8 to review" | Reviews 12/20 |

## API / MCP changes
Server state today: `/stats` has `new_today`, `milestone`, `due_new` (024 step 1). Still to remove: `NewCardsStatus`,
`AgentDeckStats`, `agent_stats`, `new_cards_status`, `_introductions` if unused, `NEW_CARD_WINDOW`,
`AddNotesReply.new_cards` / `AddCardsReply.new_cards`, the MCP tool `new_cards_per_day`, and its `INSTRUCTIONS` line.

**`ReviewLog`** gains two nullable columns, written by `deck.review_card` from the card before FSRS runs:
`stability_before: float | None`, `last_review_before: datetime | None` (UTC, `UTCDateTime`). Both null when the
card was new. Startup migration: `ALTER TABLE reviewlog ADD COLUMN …` for each missing column, like `confidence`
(spec 013); existing rows stay null (so reviews made before the deploy never count as at risk; accepted). Not
exposed anywhere.

**`GET /stats?tz=…`** → `DeckStats` (REST and MCP `deck_stats`, same model). Spec 024's fields are unchanged:
```json
{
  "total": 120, "due": 64, "new": 45, "reviewed_today": 30, "next_due": null,
  "new_today": 19, "milestone": 15, "due_new": 45,
  "streak": 4, "streak_start": "2026-11-20", "history_start": "2026-10-01", "history": "sssfsp",
  "at_risk_total": 14,  // decision 5.1; 0 when the step doesn't exist today (fewer than 10)
  "at_risk_done": 6,
  "reviews_total": 52,  // decision 5.2
  "reviews_done": 6
}
```
Invariants: `0 ≤ at_risk_done ≤ at_risk_total`, `at_risk_total = 0 or ≥ 10` when computed, `0 ≤ reviews_done ≤
reviews_total`, `reviews_done = reviewed_today − new_today`.

**Deck**: `deck.get_milestone(session) -> int` (the setting, 15 when missing or 0); `deck.set_milestone(session,
value) -> int` (`InvalidSetting` outside 1–200). `deck.stats` computes the four counts in its existing pass (the
retrievability calls are one per started card, as in `_queue`).

**MCP** (`mcp_server.py`):
- **`new_card_milestone(value: int | None = None) -> MilestoneSetting {milestone: int}`** replaces
  `new_cards_per_day`: no value reads, a value sets. Docstring: "Size of the new-card steps the app shows (default
  15). New cards are never held back: this only paces the display. Change it only when the user asks (e.g. 'only 5
  new cards a day')." Out of range: tool error "new_card_milestone must be between 1 and 200."
- **`deck_stats(tz)`** returns `DeckStats`. Docstring adds: "`at_risk_*`, `reviews_*`, `new_today`, `milestone`:
  the app's daily ladder (display only, nothing is held back)."
- **`add_notes` / `add_cards`** return `AddNotesReply(AddNotesResult)` / `AddCardsReply(AddCardsResult)` with flat
  `new: int` (never-reviewed cards after the insert) and `milestone: int`. No "today" count (no `tz` there).
  Docstring line: "New cards are due at once, after due reviews. Tell the user how many new cards wait (`new`)."
  REST `POST /notes` / `POST /cards` keep their models.
- **`INSTRUCTIONS`**: the target line becomes: "New cards are never held back: all are studyable at once, after
  due reviews, oldest first. The app shows them in steps of `milestone` cards (default 15). After adding, tell the
  user how many new cards wait (`new`). Change the step size with `new_card_milestone` only when the user asks."

**iOS `APIClient`**:
- `DeckStats` gains `newToday`, `milestone`, `dueNew` (if 024's iOS step hasn't added them yet: same names, whoever
  lands first adds them), `atRiskTotal`, `atRiskDone`, `reviewsTotal`, `reviewsDone`. Missing keys decode to 0
  (`milestone` → 15), so an older server still decodes and the caught-up path doesn't turn into "offline". The
  `init` gets the same defaults, so the widget and other callers compile unchanged.
- The in-memory client (mock) keeps per-card roles and reports the ladder from them:
  - `LA_CARTE_STARTED=n` (default 0): the first n fixture cards are started reviews (`state == .review`), served
    first; `LA_CARTE_AT_RISK=k` (default 0, k ≤ n): the first k of those are in S. The mock reports
    `at_risk_total = k` with no threshold (pytest covers the threshold).
  - Rating a card: at risk → `atRiskDone += 1`; started → `reviewsDone += 1`; new → `newToday += 1`, `dueNew −= 1`.
  - `LA_CARTE_MILESTONE` (default 15), `LA_CARTE_NEW_TODAY` (default 0) seed M and `newToday`.

## Acceptance criteria
API: pytest with `now` injected. iOS: TestStore / pure unit tests / DecodingTests unless marked UI.
"(in place)" = already implemented and tested; keep it passing.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | (in place) No hold: fresh DB, add 60 one-card notes: `due_cards(limit=200)` returns all 60, `stats.due = 60`; after reviewing 15 the other 45 are still servable at `t + 1 min` | pytest |
| 2 | (in place) Order is spec 022's: (re)learning by due, reviews by retrievability, then new cards oldest first, batch insertion order kept | pytest |
| 3 | (in place) `new_today` uses the local day in `tz`: first review at 23:30 local yesterday doesn't count, 00:10 local today does, a card introduced today then deleted still counts | pytest |
| 4 | `review_card` on a new card writes `stability_before = null, last_review_before = null`; on a started card it writes the card's stability and `last_review` from before the review | pytest |
| 5 | Migration: a DB whose `reviewlog` lacks both columns gains them at startup, old rows null; a second start changes nothing | pytest |
| 6 | At risk snapshot, `tz=Europe/Paris`: 12 started cards with retrievability at local midnight < 0.8 and 3 at ≥ 0.8 → `at_risk_total 12, at_risk_done 0`. Reviewing 5 of the 12 at 10:00 (one rated Again) → `12 / 5`. Reviewing one of the 3 → unchanged. One of the 3 whose retrievability crosses 0.8 at 15:00 is not added | pytest |
| 7 | Threshold: 9 such cards → `at_risk_total 0, at_risk_done 0`, before and after reviewing them; 10 → `10 / 0` | pytest |
| 8 | At risk exclusions: of 12 at-risk cards, one held by an open report and one deleted unreviewed → `at_risk_total 10`; one reviewed today then deleted still counts in done and total | pytest |
| 9 | Reviews: 3 servable started cards + 2 new; review 1 started (Good) and 1 new → `reviews_total 3, reviews_done 1`. At the new card's learning step (due again, servable) and after the started card is failed and served again, both stay `3 / 1` until another started card is reviewed. A review card falling due at 15:00 makes `reviews_total 4` from 15:00 | pytest |
| 10 | `reviews_done = reviewed_today − new_today` on any mixed day (property over the fixtures of AC 6–9) | pytest |
| 11 | `GET /stats` has exactly 024's keys plus `at_risk_total, at_risk_done, reviews_total, reviews_done`; fresh DB: all four 0, `milestone 15` | pytest (REST) |
| 12 | MCP `new_card_milestone()` reads 15; `(5)` returns `{milestone: 5}`, then `deck_stats` and `/stats` show 5, persisted across a new engine; `(0)`, `(201)`, `(-1)` raise the tool error and change nothing; a stored 0 reads 15; `new_cards_per_day` is no longer a tool. `add_notes` (60 notes, empty deck) replies `new 60, milestone 15`; `add_cards` too; neither has `new_cards`. `INSTRUCTIONS` contains "never held back" and "new_card_milestone", and neither it nor any tool docstring contains "must review" / "every day" about reviews | pytest (MCP) |
| 13 | `DecodingTests`: `/stats` JSON with the 7 fields decodes them; JSON without them decodes to 0 (milestone 15) | unit |
| 14 | `Ladder` reproduces the 5 mockup states of the table above exactly (rows, done flags, fractions, counter text) | unit |
| 15 | `Ladder` edge rows: W = 0 and `newToday 7` → a done row "7 new" and no current row; `newToday 15, M 15, W 3` → "15 new" done + "30 new 15/30", counter "3 new"; Reviews reopened (at risk 14/14, reviews 52/53, `newToday 20, M 15, W 10`) → rows At risk ✓, Reviews 52/53 only, counter "1 to review" | unit |
| 16 | Notices (decision 8 / Ladder rules): at risk 13/14 → 14/14 gives "At risk done"; reviews 51/52 → 52/52 gives "Reviews done"; the last at-risk card that is also the last review gives "Reviews done" only; `newToday 14 → 15, M 15` gives "15 new done"; same ladder before and after gives none | unit |
| 17 | A queue load fetches due cards and stats concurrently; either failing → offline (as today); cards → `.studying`; no cards → `.caughtUp(nextDue)` / `.empty` from the same stats; no second stats request follows | unit |
| 18 | After a successful rating, one stats fetch updates the ladder and, per AC 16, sets the notice (`expireNotice()`); a rating that empties the batch triggers one queue load instead, which can set the notice. A failed post-rating stats fetch keeps the old ladder and the phase. A load, foreground or auto-refresh never sets a step notice | unit |
| 19 | Tapping `study.remaining` opens the popover (`isMilestonesShown`) when a ladder is loaded; with no ladder yet, it does nothing | unit |
| 20 | Mock, `LA_CARTE_STARTED=2 LA_CARTE_AT_RISK=1 LA_CARTE_MILESTONE=1`: counter "1 at risk"; popover shows `study.milestone.atRisk` "At risk 0/1". Rate → notice "At risk done", then counter "1 to review", popover At risk ✓ + Reviews 1/2. Rate → "Reviews done", counter "1 new", popover At risk ✓, Reviews ✓, "1 new 0/1". Rate → "1 new done" over the caught-up screen | UI |
| 21 | Mock, `LA_CARTE_STARTED=1`: counter "1 to review", popover one row "Reviews 0/1" and no at-risk row | UI |
| 22 | Mock, `LA_CARTE_MILESTONE=2 LA_CARTE_NEW_TODAY=4`: counter "2 new"; popover "4 new" ✓ then "6 new 4/6" with its progress bar | UI |
| 23 | The counter is a button: `study.remaining` has the button trait and the accessibility label "Milestones" (value = the counter text); the popover has no title, no button and no text besides its rows | UI |
| 24 | Pink only on the counter's number: not its unit, the popover, the bar, the checkmarks or the notice (screenshots, light / dark / forest) | UI (screenshot review) |
| 25 | Docs: `docs/architecture.md` describes `/stats`' four ladder counts, the `ReviewLog` columns, the `settings` value as step size and `new_card_milestone`, and drops the "daily target" text. `docs/design-system.md` gets design-lead's lines: rule 4 names the counter number in any unit; the Glass section lists the counter capsule next to `CircleIconButton` and the popover under system glass | review |

## Screens & states
**Study top bar, counter** (`study.remaining`), between the Deck and Add circles:
- A `Button` that opens the popover, styled `.buttonStyle(.glass)`: the system's glass capsule, the peer of the
  two `CircleIconButton`s (Study's top bar is custom, not a system toolbar; if the engineer finds a real `.toolbar`
  item simpler, that's fine too, same look). Height 44 pt like the circles, no extra background or fill.
- Label text `.meta`, secondary ink, the number in accent (rule 4), `.contentTransition(.numericText())` (opacity
  only under Reduce Motion), `.monospacedDigit()`. No chevron. Capped at `.accessibility2` like today.
- VoiceOver: label "Milestones", value the counter text ("8 at risk"), button trait.
- Shown in the same cases as today (studying, cards loaded, no notice, not editing). A notice or an edit hides it.

**Milestones popover** (`study.milestones`): `.popover(isPresented: $store.isMilestonesShown, arrowEdge: .top)`
with `.presentationCompactAdaptation(.popover)`. System glass only: no `.presentationBackground`, no fills.
- VStack, leading, spacing `m`, padding `m`, `idealWidth` 220; scrolls at accessibility sizes. No title, no
  buttons, no sentences. A tap outside dismisses it. It updates live if the ladder changes while open.
- Done row: label (`.body`, secondary ink), `Spacer`, `checkmark` (`.fontWeight(.medium)`, secondary ink).
  VoiceOver: "At risk, done".
- Current row: label (`.body`, ink), `Spacer`, "done/total" (`.body`, secondary ink, `.monospacedDigit()`); under
  it, spacing `s`, `ProgressView(value: done, total: total).tint(Theme.ink)`. VoiceOver: "Reviews, 30 of 52".

**Step notice** (`study.milestoneNotice`): "At risk done" / "Reviews done" / "{n} new done", in the notice slot,
styled like "Reported" (secondary ink, no accent), `.success` haptic.

Screenshots (qa-validator; light + dark, plus forest for the popovers), mock env as in AC 20–22:
- `study-counter-atrisk`, `study-milestones-atrisk` (AC 20 start)
- `study-milestone-notice` ("At risk done", AC 20)
- `study-milestones-reviews` (AC 20 after one rating)
- `study-milestones-new` (AC 20 after two ratings)
- `study-milestones-normal` (AC 21)
- `study-milestones-many` (AC 22)

## TCA shape (iOS)
Module: `StudyFeature`. No child reducer: the popover is a few lines of view over state.

- New file `Ladder.swift`: `struct Ladder: Equatable` built from `DeckStats`, with `rows: [Row]`
  (`Row { label: String, done: Int, total: Int, isDone: Bool }`, a done-only new row has no fraction),
  `current: Row?`, `counter: (count: Int, unit: String)?` (nil → the fallback batch counter),
  `func notice(after previous: Ladder) -> String?`. Pure, unit-tested (AC 14–16).
- State: `var ladder: Ladder?`; `var isMilestonesShown = false` (binding, like `isReportMenuShown`);
  `Notice` gains `.stepDone(String)` (text "\(label) done"; the haptic trigger includes it).
- Actions:
  - `queueResponse(Result<Queue, any Error>, afterRating: Bool)` replaces `cardsResponse` / `statsResponse`
    (`Queue` = cards + stats; naming up to the engineer). Sets `ladder`; when `afterRating`, sets the notice per
    `Ladder.notice(after:)`.
  - `ladderResponse(Result<DeckStats, any Error>)`: the post-rating stats; success updates `ladder` and may set the
    notice; failure is ignored.
  - `remainingTapped`: guarded by `ladder != nil`, sets `isMilestonesShown`.
  - `reviewResponse(.success)`: as today, plus `cards.isEmpty ? fetchQueue(afterRating: true) : fetchLadder()`.
    `fetchLadder` is cancellable (its own id, `cancelInFlight`) so only the latest answer lands.
- Dependencies unchanged (`apiClient.dueCards`, `apiClient.stats`, `clock`). No delegate actions. Widget and Settings
  ignore the new fields.

## Accessibility identifiers
- `study.remaining`: the counter button (unchanged id).
- `study.milestones`: popover root.
- `study.milestone.atRisk`, `study.milestone.reviews`, `study.milestone.newDone`, `study.milestone.new`: its rows
  (`newDone` = the finished new row, `new` = the current new row).
- `study.milestoneNotice`: the step notice.

## Implementation order
1. **api-engineer**: AC 4–12 (1–3 stay green) plus the architecture.md part of AC 25. Additive on `/stats`; deploys
   on its own (today's app ignores the new keys).
2. **ios-engineer**: AC 13–19 (`APIClient` + `DecodingTests`, in-memory mock + env vars, `Ladder`, `StudyFeature`,
   `StudyView`). Can start in parallel with step 1 against the mock; merge after it. **design-lead** writes the
   design-system.md lines (AC 25) in parallel.
3. **code-reviewer**, then **qa-validator**: AC 20–24 as UI tests (`StudyMilestonesUITests`), the screenshots above,
   plus one e2e check that `/stats` carries the four counts.

## Out of scope
- Any hold, cap, reorder or "pause new cards"; the ladder never changes the queue.
- Explanation text, a ladder screen, confetti, sounds, a history of past days' ladders.
- An in-app setting or REST endpoint for M (backlog #44); a setting for the 0.8 / 10 thresholds.
- The widget: it keeps 024's `toReview` count (decision 9 there). Showing the ladder's counter on the widget is
  backlog #49.
- Changing the counter's accent or `secondaryInk` contrast (separate decision for the user).
- A `tz` on `add_notes` / `add_cards`.
