# 021 — New cards: daily milestones, never held

Status: ready
Owners: api-engineer (server, first), ios-engineer (Study counter + popover), design-lead (design-system.md lines)
Depends on: 014a (notes, sibling burying), 015a (reports), 018 (auto-refresh), all merged. Backlog #43.
Design reference: none new. The counter is Study's existing top-bar counter (specs 001, 009c). The popover uses the
native title-menu affordance (text + `chevron.down`, as in Photos / Files / Notes) and a system popover (Liquid
Glass, design-system "Glass" section). Design input: design-lead, 2026-11-22.

**Revision 2026-11-22 (user feedback on the deployed hard cap).** In v1 the server held never-reviewed cards back
past N a day. The user said: "In the app, you should always see the new cards you can learn, even though it's a
lot. But at the same time, you should have intermediate milestones about the limit per day, so that you don't get
discouraged. [...] If you click on it, you see if you are still in the first milestone or if you are three
milestones down the line [...]. The idea that you add new cards and you can't see them, even on a tryout session to
learn a lot of new things, is bad." So v1's hold, its `next_due` rule and its one-per-note-per-day rule are gone
(an api-engineer hotfix removes the hold first). The stored number becomes the **milestone size**.

## Goal
Every new card can be studied right away, however many an agent adds. The app keeps the session from feeling
endless: the number at the top counts toward the next **milestone** of M new cards (default 15), and tapping it shows
how many milestones the user reached today and how many new cards wait. Nothing blocks and nothing nags.

## User stories
- As the user, an agent adds 60 words, and I can learn all of them tonight if I want to. The counter says
  "15 to review", then "Milestone 1 reached", then counts toward the next 15.
- As the user, I tap the counter and see that I'm at milestone 3, 4 of 15, with 21 new cards waiting.
- As the user, I tell my agent "only 5 new cards a day", and my milestones become 5 cards.
- As an agent, after `add_notes` I tell the user how many new cards wait, about how many milestones that is.

## Decisions
1. **No hold.** Every never-reviewed, non-held (spec 015) card is in the servable queue as soon as it's added.
   Sibling burying stays as in spec 014 (6 h, or until the reviewed sibling is due again), for new cards too.
   v1's "one new card per note per day" rule is dropped: it only existed to spread the cap.
2. **Queue order: started cards first, then new cards, oldest first.** The servable queue sorts by
   `(never reviewed, due if reviewed, _card_order)`:
   - Cards already reviewed (`learning`, `review`, `relearning`), most overdue first. That's the order today.
   - Then never-reviewed cards in `_card_order`: oldest `created_at`, and a batch keeps its insertion order and
     field order.

   Why: a due review is at risk of being forgotten, and a new card loses nothing by waiting. Anki's default is the
   same ("new cards after reviews"). It also gives every session the same shape: clear the reviews, then learn as
   many new cards as you like. Oldest first keeps an agent's batch in the order it was added. The one-card-per-note
   rule still applies, and a (re)learning card still wins its note.
3. **Milestone size M = the stored setting.** The column stays `settings.new_cards_per_day`, so there's no
   migration. Migration 021 and the `settings` table from v1 stay. Default 15, valid range 1–200. 0 no longer means
   anything: a stored 0 (v1's "paused") reads as the default 15. The MCP tool is renamed to `new_card_milestone`, a
   clean rename with no alias. Agents list tools on every connection and the only callers are the user's agents, so
   an alias would just be dead weight.
4. **"Today" = the local calendar day**, the same `tz` that `/stats` already uses for `reviewed_today` and
   `streak`. v1 picked a rolling 24 h window because the cap decided what the server serves, and `/cards/due` has no
   time zone. Now the number only feeds a display, and the app sends its time zone, so the calendar day wins: the
   count goes back to 0 at local midnight, which is what "today" means to the user. A rolling window would make the
   count drop in the middle of a session.

   `new_today` = the number of distinct cards whose **first** `ReviewLog` row falls in today's local day. It's
   counted from `ReviewLog`, so a card that was introduced and then deleted still counts.
5. **The milestone maths lives in the app, and it's display only.** The server reports `new_today` and `milestone`.
   The app derives:
   - `reached = new_today / M` (integer division);
   - `into = new_today % M`.

   This isn't scheduling: it decides nothing about what is served.
6. **The counter's N.** `study.remaining` keeps its text "N to review". N is now:
   `started cards in the loaded batch + min(new cards in the batch, M - into)`.
   So the counter tops out at the reviews plus at most M, and never reads "300 to review". When the last new card
   of a milestone is rated, the next one starts: the app reloads the queue so (re)learning cards due by then come
   first, and N counts toward the next milestone.
7. **The app gets the numbers with every queue load.** Each load fetches `/cards/due?limit=100` and `/stats`
   concurrently and handles them as one response. That also replaces today's second, sequential `/stats` call when
   caught up. Between loads the app keeps `new_today` and `new` current itself. When a review of a card that was
   `state == .new` succeeds, `new_today += 1` and `new -= 1`. The next load replaces both with the server's values.
8. **Milestone moment (small, optional to keep).** Rating the card that completes a milestone shows the notice
   "Milestone K reached" in the existing notice slot, for the usual notice duration, and plays the existing
   `.success` haptic. It shows only after a rating, never on launch or reload, and never when reviews alone empty
   the counter. There's no screen and no stop: the session goes on, and the notice is the natural place to stop.
9. **REST**: `/stats` gains two fields. No new endpoint, and no in-app setting (backlog #44).

## API / MCP changes
Server state after this spec, starting from the hotfix. Remove v1's `_admit_new`, `NEW_CARD_WINDOW`,
`NewCardsStatus`, `AgentDeckStats`, `AddNotesReply.new_cards` and `AddCardsReply.new_cards`, and v1's `next_due`
slot rule. `next_due` goes back to the 014/015 definition.

**`GET /stats?tz=…`** → `DeckStats` (both REST and MCP `deck_stats`):
```json
{
  "total": 120, "due": 64, "new": 45, "reviewed_today": 30, "next_due": null, "streak": 4,
  "new_today": 19,   // distinct cards first reviewed today (local day in tz), from ReviewLog
  "milestone": 15    // the milestone size M, 1-200
}
```
`due` now includes every servable new card. `new` is unchanged: every never-reviewed card. A report-held new card
still counts in `new`, which is good enough for "waiting".

**`GET /cards/due`**: same shape, ordered as in decision 2.

**Deck**:
- `deck.get_milestone(session) -> int`: the setting, or 15 when it's missing or 0.
- `deck.set_milestone(session, value) -> int`: raises `InvalidSetting` outside 1–200 and returns the value.

**MCP** (`mcp_server.py`):
- **`new_card_milestone(value: int | None = None) -> MilestoneSetting {milestone: int}`** replaces
  `new_cards_per_day`. With no value it reads the setting; with a value it sets it.
  - Docstring: "Size of the daily milestones the app shows for new cards (default 15). New cards are never held
    back: this only paces the display. Change it only when the user asks (e.g. 'only 5 new cards a day')."
  - Out of range raises a tool error: "new_card_milestone must be between 1 and 200."
- **`deck_stats(tz)`** returns `DeckStats`, which now has `new_today` and `milestone`. Docstring: "`new_today`: new
  cards first studied today in `tz`; `new_today // milestone` milestones reached."
- **`add_notes` / `add_cards`** return `AddNotesReply(AddNotesResult)` / `AddCardsReply(AddCardsResult)` with flat
  `new: int` (never-reviewed cards in the deck after the insert) and `milestone: int`.
  - They carry no "today" count: these tools take no `tz`, and a UTC day would disagree with the app. The docstrings
    point to `deck_stats(tz)` for today's progress.
  - Docstring line: "New cards are due at once, after due reviews. Tell the user how many new cards wait (`new`),
    about `ceil(new / milestone)` milestones."
  - REST `POST /notes` / `POST /cards` keep their models.
- **`INSTRUCTIONS`**: the v1 cap line becomes: "New cards are never held back: all are studyable at once, after due
  reviews, oldest first. The app paces them in daily milestones of `milestone` cards (default 15). After adding,
  tell the user how many new cards wait (`new`), about how many milestones. Change the size with
  `new_card_milestone` only when the user asks."

**iOS `APIClient`**:
- `DeckStats` gains `newToday: Int` and `milestone: Int`. Decoding a body without them gives `0` / `15`, so an older
  server still decodes and the caught-up path doesn't turn into "offline".
- The `init` gets defaults (`newToday: Int = 0, milestone: Int = 15`), so the widget and other callers compile
  unchanged.
- The in-memory client (mock):
  - orders `dueCards` like decision 2;
  - tracks `newToday`: cards reviewed while `state == .new`, plus a seed;
  - reads `LA_CARTE_MILESTONE` (default 15) and `LA_CARTE_NEW_TODAY` (default 0) from the environment, for QA.

## Acceptance criteria
API criteria are pytest with `now` injected. iOS criteria are TestStore / DecodingTests unless marked UI.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | No hold: fresh DB, add 60 one-card notes. `due_cards(limit=200)` returns all 60 and `stats.due = 60`. After reviewing 15 of them, the other 45 are still servable at `t + 1 min` | pytest |
| 2 | Order: a `review` card due 1 h ago, a `relearning` card due now and 3 new cards (one created 2 days before the review card's due) give `/cards/due` = reviewed cards first (most overdue first), then the 3 new cards oldest first, in insertion order within a batch | pytest |
| 3 | Siblings: a person note with 3 new directions serves one (field order). After it is reviewed, the next one is buried only per spec 014 (until `min(t + 6 h, its due)`), not 24 h | pytest |
| 4 | `next_due` follows 014/015 only: with only new cards left, `due > 0` and the app is never "caught up" while a new card exists. With nothing servable, `next_due` = the earliest ready time of a started card | pytest |
| 5 | `new_today` uses the local day: with `tz=Europe/Paris`, a card first reviewed at 23:30 local yesterday and again today doesn't count; a card first reviewed at 00:10 local today does; a card introduced today and then deleted still counts; `tz=UTC` can give a different value for the same data | pytest |
| 6 | `GET /stats` has exactly `{total, due, new, reviewed_today, next_due, streak, new_today, milestone}`; fresh DB `milestone = 15` | pytest (REST client) |
| 7 | MCP `new_card_milestone()` reads 15. `new_card_milestone(5)` returns `{milestone: 5}`, after which `deck_stats` and `/stats` show `milestone = 5` and it persists across a new engine on the same file. `(0)`, `(201)` and `(-1)` raise the tool error above and leave it unchanged. A row with a stored 0 reads as 15. `new_cards_per_day` is no longer a tool | pytest (MCP) |
| 8 | MCP `add_notes` with 60 basic notes on an empty deck replies `new = 60, milestone = 15`; `add_cards` carries `new` and `milestone` too; neither has `new_cards` | pytest (MCP) |
| 9 | `INSTRUCTIONS` contains "never held back" and "new_card_milestone"; the `add_notes` docstring mentions `milestone` | pytest (substring) |
| 10 | Report-held new cards (015) stay out of the queue and still count in `new` | pytest |
| 11 | `DecodingTests`: `/stats` JSON with `new_today: 19, milestone: 15` decodes to `newToday 19, milestone 15`; JSON without them decodes to `0 / 15` | unit |
| 12 | Each queue load fetches due cards and stats concurrently; when either fails, the screen shows offline (as today). With cards, the phase is `.studying`; with no cards, `.caughtUp(nextDue)` / `.empty` from the same stats. No separate stats request follows | unit |
| 13 | Counter N (decision 6): a batch of 3 started + 40 new cards with `newToday 4, M 15` shows "14 to review". With `newToday 15` (reached 1, into 0) it shows "18 to review". A batch of only started cards shows their count | unit (state) + UI (`study.remaining` label) |
| 14 | Rating a card whose state was `.new` (success) increments `newToday` and decrements `new`. Rating a started card changes neither | unit |
| 15 | Rating the new card that makes `newToday % M == 0` sets the notice to "Milestone K reached" (K = `newToday / M`), triggers the success haptic and reloads the queue. A reload or launch with `newToday` already a multiple of M shows no notice | unit |
| 16 | The counter is a button with a `chevron.down` when `newToday + new > 0`. Tapping it opens the milestones popover (`study.milestones`). Otherwise it is plain text with no chevron, and tapping does nothing | unit (both) + UI (button case) |
| 17 | Popover content (static strings, unit-tested), per the Screens section: marks = `reached` checkmarks + 1 open circle while new cards wait; status "Milestone {reached+1}: {into} of {M} new cards", or "{newToday} new cards today" when none wait; waiting line inflected ("1 new card waiting" / "21 new cards waiting" / "No new cards waiting"); note per `reached` 0 / 1 / ≥2. Above 6 reached, the marks become the text "{reached} milestones today" | unit + UI |
| 18 | The mock (`LA_CARTE_API=mock`, `LA_CARTE_MILESTONE=2`): rating 2 new cards shows "Milestone 1 reached"; then the popover shows 1 checkmark and "Milestone 2: 0 of 2 new cards", "1 new card waiting" | UI |
| 19 | Pink only on the counter's number: not the chevron, the popover, the progress bar or the notice | UI (screenshot review) |
| 20 | Docs: `docs/architecture.md` describes the queue order, `new_today` / `milestone` on `/stats`, the `settings` value as milestone size and the `new_card_milestone` tool, and drops v1's cap. `docs/design-system.md` gets design-lead's lines (accent rule 4, popovers under Glass, the counter component) | review |

## Screens & states
**Study top bar, counter** (`study.remaining`):
- Text "N to review", `.meta`, secondary ink, the number in accent (rule 4), `.contentTransition(.numericText())`
  (opacity only under Reduce Motion).
- When it opens the popover (#16), it's a plain `Button` whose label is the text plus `chevron.down`. The chevron
  uses `.font(.meta.weight(.semibold))`, `.imageScale(.small)` and secondary ink.
- Hit area at least 44 pt, `.contentShape(.rect)`, no glass, no capsule: the bar keeps exactly two glass circles.
- VoiceOver: label "N to review", hint "Shows today's milestones".
- The `.accessibility2` cap covers the chevron too.
- The notice slot rules are unchanged: a notice or an edit hides the counter.

**Milestones popover** (`study.milestones`):
- `.popover(isPresented:arrowEdge: .top)` with `.presentationCompactAdaptation(.popover)`. The system draws the glass:
  no `.presentationBackground`, no fills.
- Layout: a VStack, leading-aligned, spacing `s`, padding `m`, `idealWidth` 280. At accessibility sizes it scrolls.
- No title, no buttons. A tap outside dismisses it.

The popover's rows, top to bottom:
1. `study.milestoneMarks` (`.body`): `checkmark.circle.fill` in ink for each milestone reached, then one `circle` in
   secondary ink for the milestone in progress (only while new cards wait). Above 6 reached, it's the text
   "{reached} milestones today" instead.
2. `study.milestoneStatus` (`.body`, ink):
   - new cards wait: "Milestone {reached+1}: {into} of {M} new cards", with
     `ProgressView(value: into, total: M).tint(Theme.ink)` under it;
   - none wait: "{newToday} new cards today", with no bar.
3. `study.milestoneWaiting` (`.meta`, secondary ink): "^[\(new) new card](inflect: true) waiting", or
   "No new cards waiting".
4. `study.milestoneNote` (`.meta`, secondary ink):
   - 0 reached: "New cards come in steps of {M}. Stop at any milestone."
   - 1 reached: "First milestone done. Going further is up to you."
   - ≥2 reached: "Each new card today comes back as reviews in the days ahead."

**Milestone notice** (`study.milestoneNotice`): "Milestone K reached" in the notice slot, secondary ink, no accent.

Screenshots (light + dark, plus forest for the popover), all with the mock and `LA_CARTE_MILESTONE=2`:
- `study-counter-milestone`: the counter with its chevron (new cards waiting).
- `study-milestones-first`: popover, 0 reached.
- `study-milestones-second`: popover, 1 reached (seed `LA_CARTE_NEW_TODAY=2`).
- `study-milestones-many`: popover, 2 or more reached, still in progress (seed `LA_CARTE_NEW_TODAY=4`).
- `study-milestones-done`: popover, no new cards waiting (after rating all three fixtures).
- `study-milestone-notice`: the notice right after a milestone.
The plain counter (reviews only, no chevron) has no mock fixture: every mock card starts new. A unit test covers it
(#16), and it gets no screenshot.

## TCA shape (iOS)
Module: `StudyFeature` (no new module, no child reducer: the popover is a few lines of view over state).

State:
- `var today: Today?` with `struct Today: Equatable { var newToday: Int; var milestone: Int; var waiting: Int }`,
  set from `DeckStats` on each load.
- `var isMilestonesShown = false`: a binding, like `isReportMenuShown`.
- `Notice` gains `.milestoneReached(Int)`.
- Computed:
  - `remaining` (decision 6);
  - `reached`, `into`;
  - `canShowMilestones`: `today.map { $0.newToday + $0.waiting > 0 } ?? false`.

Actions:
- `remainingTapped`: guarded by `canShowMilestones`, sets `isMilestonesShown`.
- The load response becomes one action carrying cards + stats, e.g. `queueResponse(Result<Queue, any Error>)`,
  replacing the `cardsResponse` / `statsResponse` pair. Naming is up to the engineer.
- `reviewResponse(.success)`: if the removed card was `.new`, update `today`. On a multiple of M, set the notice
  (`expireNotice()`) and reload the queue (`fetchDueCards`), keeping the visible card rule.

Dependencies: unchanged (`apiClient.dueCards`, `apiClient.stats`, `clock`).

Delegate actions: none new. The widget and Settings keep reading `stats()` and ignore the new fields.

## Accessibility identifiers
- `study.remaining`: the counter, now a button when it opens the popover (unchanged id).
- `study.milestones`: popover root.
- `study.milestoneMarks`, `study.milestoneStatus`, `study.milestoneWaiting`, `study.milestoneNote`: its rows.
- `study.milestoneNotice`: the "Milestone K reached" notice.

## Implementation order
1. **api-engineer**: AC 1–10 plus the architecture.md part of 20, on top of the no-hold hotfix. It deploys on its
   own: the extra `/stats` fields are additive, and today's app ignores them.
2. **ios-engineer**: AC 11–17 (`APIClient`, `DecodingTests`, in-memory mock + env vars, `StudyFeature`,
   `StudyView`). **design-lead** writes the design-system.md lines (AC 20) in parallel; ios-engineer doesn't wait
   for them.
3. **code-reviewer**, then **qa-validator**: AC 13, 16–19 as UI tests (`StudyMilestonesUITests`), the screenshots
   above, plus one e2e check that `/stats` carries `new_today` / `milestone`.

## Out of scope
- Any hold, cap or "pause new cards". A user who wants fewer new cards simply stops at a milestone.
- An in-app setting or REST endpoint for M (backlog #44).
- The widget: it still shows `stats.due`, which now includes every new card ("64 to review" where the app says
  "14"). Aligning it is backlog #45.
- Streak-like rewards, confetti, sounds, a milestone history across days.
- A `tz` on `add_notes` / `add_cards`.
- Reordering new cards (priority, random), or interleaving new cards with reviews.
