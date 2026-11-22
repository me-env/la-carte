# 024 — Widget: the streak as a history grid (with freezes)

Status: ready (v3 approved by the user on 2026-11-22: "the design you sent looks great"; final design choices
below)
Owners: api-engineer (step 1: `/stats` fields, freeze rule) → ios-engineer (step 2: contract, grid, widget,
renders) → qa-validator. design-lead updates `docs/design-system.md` (Widget section, accent rule 3) with step 2.
Depends on: 007 (widget, merged). The count needs 021's `new_today` and `milestone` on `/stats`: 024 step 1 adds
exactly those two fields as 021 defines them (additive, read-only), so 024 doesn't wait on 021's milestone UI.
Replaces in 007: the widget layout, AC 2 (streak cases), AC 16–19 and the gallery tiles. Everything else in 007
(App Group, Keychain, provider, cache, refresh, theme, signing) stays. Settles backlog #46.
Design reference: `docs/design/renders/024/streak-widget-v3.png` (design-lead mockup drawn from the reference
layout, not a real render). Earlier rounds are in the same folder: v1 sized dots, then the letters vs shapes
comparison and the pentagon vs diamond comparison. Feel from 02-editor-light.jpg / 01-editor-dark.jpg (quiet, one
thing at a time) and 05-theme-forest.jpg.

## Goal
User feedback (2026-11-22): "The widget just showing a two-day streak does not motivate anyone to continue. Can we
instead have something like the GitHub contribution thing: a line of grey dots representing days, the last ones the
most recent days, coloured if you worked that day. You can see the streak by counting [...]. Then another kind of dot
represents a week [...]. Each time you reach the limit of dots shown on screen, it goes up another layer: then it's
months, and then years."

Follow-up decisions from the user (same day):
- **Units by shape.** A different shape per unit, all the same size. Size as the unit cue "feels more like a UI bug
  than a feature".
- **The grid is always full.** Empty or partial rows "are really not pretty".
- **Show the past, not the future.** Today is the last slot. Going back, the grid shows the actual history: the
  current streak, then whatever came before it, gaps included.
- **A forgiving streak.** One missed day now and then is frozen instead of breaking the streak.

After this ships, the widget is a 4 × 7 grid of marks ending with today. You can count the current streak's dark
marks, see recent gaps and older runs in grey, and watch a long streak level up from days to weeks, months and
years.

## User stories
- As the user, I see three dark dots ending in a pink one and know I have a 3-day streak and studied today.
- As the user, I see a pink ring in the corner and know today is still to do.
- As the user, I see last week's pattern: one day alone, a gap, then my 3-day streak.
- As the user, I missed one day last week and my streak survived: that day is a hollow ring, not a gap.
- As the user, after two months my oldest marks became squares (weeks), and later pentagons (months) and stars
  (years).
- As the user, the number on the widget matches the counter in Study.

## Decisions
1. **A studied day** = a local calendar day with at least one review (any rating, REST or MCP), as in 007. Showing up
   is what counts. Thresholds like "finished all due cards" or "reached a milestone" were rejected: harder to
   explain, and they punish busy days.
2. **Time zone**: the `tz` the app already sends to `/stats` (device zone, 007). Day boundaries are local midnights,
   DST-correct. Travelling re-buckets past reviews into the new zone's days. That's accepted, as in 007.
3. **Freeze rule (automatic; nothing to buy or earn; no counter shown).** Walk the local days chronologically, from
   the first review day to yesterday. A missed day *x* is **frozen** when all three hold:
   - the day before *x* is studied;
   - no frozen day lies in the 6 days before *x* (so at most one freeze in any 7 consecutive days);
   - the day after *x* is studied, or is today (studied or not yet).

   Any other missed day is **missed**, and a missed day ends the run. So two missed days in a row always break the
   streak, and neither shows as frozen. Freezes don't accumulate. The walk is chronological, so a freeze is spent
   when the day is missed: of two misses 4 days apart, the **later** one breaks the run.

   A missed yesterday is frozen provisionally while today is open. If today ends without a review, tomorrow's walk
   sees two missed days in a row and the run breaks.
4. **Streak** `S` = the number of days in the current run, frozen days included. The run ends today if today is
   studied, otherwise yesterday. Today, not yet studied, is **pending**: neither counted nor missed. `streak_start`
   is the run's first day, or null when `S = 0`.

   Changes vs 007:
   - Reviews today, yesterday and 3 days ago (2 days ago missed): 2 before, now 4.
   - Last review 2 days ago: 0 before, now 2 (yesterday is frozen).
   - Last review 3 days ago: still 0.
5. **Data from the server: the facts, not the layout.** `/stats` gains:
   - `history`: one character per local day, from the first review day to today;
   - `history_start`, `streak_start`;
   - `due_new` (decision 9).

   The grid (which periods, which marks) is display maths and lives in the widget. No scheduling is involved. A
   character per day is small: three years ≈ 1.1 KB.
6. **The widget's "today" is the last day of `history`**, never the device clock. A cached response
   (`widget.lastStats`, 007) renders exactly as it was fetched. The refresh at local midnight (007 AC 21) keeps it
   current.
7. **Families: systemSmall and systemMedium**, one widget kind (`DeckWidget`). Lock Screen stays backlog #14.
8. **Pink = today (default, user didn't object).** Today's mark is the widget's only accent: a ring while today is
   still to do, filled once studied. The streak number is `ink`. A run of pink marks would be a pink fill, which
   the accent rule forbids. This replaces accent rule 3 in `docs/design-system.md`.
9. **The count (#46; default: the small widget keeps it on top).** Since 021 v2, `stats.due` includes every new card,
   so "300 to review" is possible. The widget shows the counter Study shows (021 decision 6), from `/stats` alone:
   `toReview = (due − due_new) + min(due_new, milestone − new_today % milestone)`.
   `due_new` (new field) = the never-reviewed cards in the servable queue (a subset of `due`). The function is
   `DeckStats.toReview` in `APIClient`. Study's batch is capped at 100, so the two can differ only when more than
   100 cards are due. That's accepted.
10. **Counting.** Up to 28 days of history, the dark marks count the streak exactly. Beyond that, counting is exact
    to the unit: a mark that straddles the streak's start is dark when at least half its days are in the streak. So
    "6 pentagons + 22 dots" reads as about 6 months and 22 days. The label gives the exact number ("200-day streak").

## The grid (rules; `StreakGrid`, pure, unit-tested)
**Input:**
- `history`, `history_start`, `streak_start`;
- today = the last day of `history`;
- a Gregorian `Calendar` in the device time zone.

**Output:** exactly **28 marks**, oldest first, laid out in 4 rows × 7, row-major. The top-left is the oldest, the
bottom-right is today. Every slot holds a mark; there are no empty, partial or "not yet" slots.

**Periods (end-anchored, contiguous, no gaps).** Read back from today, the grid is:
1. `D` day marks: the last `D` days, today included;
2. before them, `W` week marks: 7-day blocks counting back;
3. before them, `Mo` month marks: calendar-month blocks counting back (`date − n months`, Foundation clamping);
4. before them, `Y` year marks: calendar-year blocks counting back.

So `D + W + Mo + Y = 28`, and the marks read oldest → newest as years, months, weeks, days. Different shapes share
rows.

**Choosing D, W, Mo, Y.** The grid must reach back to the run's first day (`streak_start`, or today when `S = 0`).
1. **Level** = the finest of these that can reach it, with at least one full row of days (`D ≥ 7`):
   - days only (`D = 28`);
   - days + weeks;
   - days + weeks + months;
   - all four.
2. **Within the level**, the most days, then the most weeks, then the most months. The rest of the marks are the
   level's unit.

This is "fill the screen, then go up a layer": weeks appear past 28 days, months when 7 days + 21 weeks no longer
reach (~154 days), years when 7 days + 21 months no longer reach (~2 years). Days before `history_start` count as
missed. It's a brute-force search over at most 28³ combinations: trivial, no cleverness needed.

**Status of a mark.**
- **Day:** studied or frozen inside the current run → `run` / `frozenRun`; studied or frozen before it →
  `older` / `frozenOlder`; missed or before the history → `missed`; today → `todayPending` or `todayStudied`.
- **Week, month, year:** `run` if at least half its days are in the current run. Else `older` if at least half its
  days were studied or frozen. Else `missed`. A frozen day inside a coarse period counts as done, so freezes only
  ever show on day marks; there's no hollow week, month or year.

**Marks.** All four shapes are drawn to the same ink area (about 64 pt²) at a 19 pt pitch. The grid is 133 pt wide
and 76 pt tall.

| Unit | Shape |
|---|---|
| day | circle Ø 9 |
| week | rounded square 8.5, radius 2 |
| month | rounded regular pentagon, point up, circumradius 5.5, corner radius 1.2, drawn 0.25 pt low |
| year | rounded 5-point star, outer radius 7.4, inner radius 3.7, corner rounding 1.2, drawn 0.5 pt low |

| Status | Look (tokens; the same in all themes) |
|---|---|
| `run` | `ink`, solid |
| `older` | `secondaryInk` at 60%, solid (lighter, so the current run stands out) |
| `missed` | `secondaryInk` at 35%, solid |
| `frozenRun` (day only) | the circle hollow, 1.5 pt inside stroke, `ink` |
| `frozenOlder` (day only) | the same, `secondaryInk` at 60% |
| `todayPending` | a 2 pt `accent` ring over a `secondaryInk` 35% fill |
| `todayStudied` | `accent`, solid |

Tinted and clear Home Screens (`widgetRenderingMode != .fullColor`):
- today's mark is `.widgetAccentable()`;
- `ink` becomes `.primary`, and `secondaryInk` (35% and 60% included) becomes `.secondary`;
- frozen and today stay distinct by stroke (a 1.5 pt hollow circle vs a 2 pt ring over a fill).

## Screens & states
**systemSmall** (system content margins, leading-aligned, `Theme.background` via `containerBackground`):
```
┌───────────────────┐
│ 8 to review       │  status   .body medium ink: "N to review" (toReview) / "All caught up" / "No cards yet"
│ ■ ■ ■ ■ ■ ■ ●     │  grid     4 × 7, always full, bottom-anchored
│ ● ● ● ● ● ● ●     │           (oldest top-left; shapes: ● day ■ week ⬟ month ★ year)
│ ● ● ● ● ● ● ●     │
│ ● ● ● ● ○ ● ◎     │           ○ frozen, ◎ today (pink)
│ 60-day streak     │  label    .meta semibold ink "N-day streak"; S = 0: "Start a streak today" .meta secondaryInk
└───────────────────┘
```
**systemMedium**: two columns, both bottom-aligned to the label's baseline.
- **Left**: as 007's small widget.
  - Due: the hero "8" (`.cardFace`, monospaced digits, `ink`) over "to review" (`.meta`, `secondaryInk`).
  - Caught up: "All caught up" (`.body` medium) over "Next at 18:40" / "Next on 24 Nov".
  - Empty deck: "No cards yet" over "Ask your agent to add some".
- **Right**: the same grid and label as small, trailing on the content margin.

**Unavailable** (no fetch, no cache): only "Can't reach your deck" (`.meta`, `secondaryInk`), as in 007.

**VoiceOver**: one element, e.g. "9-day streak, today still to do, 8 to review", or "3-day streak, studied today,
all caught up". The marks are decorative.

**Scenarios** (fixtures; today = Sun 2026-11-22; studied days listed, every other day missed; the same set for
pytest, unit tests, renders and the gallery). Expected grid, rows separated by `/`, oldest first. The notation:
- `#` run, `+` older, `.` missed, `o` frozen in the run;
- `T` today studied, `P` today pending;
- a prefix `W` / `M` / `Y` marks a week, month or year (no prefix = a day).

| id | Studied | streak, start | D W Mo Y | Expected grid |
|---|---|---|---|---|
| `zero` | none | 0, null | 28 0 0 0 | `. . . . . . . / . . . . . . . / . . . . . . . / . . . . . . P` |
| `three` | 11-20..11-22 | 3, 11-20 | 28 0 0 0 | `. . . . . . . / . . . . . . . / . . . . . . . / . . . . # # T` |
| `nine` | 11-13..11-21 | 9, 11-13 | 28 0 0 0 | `. . . . . . . / . . . . . . . / . . . . # # # / # # # # # # P` |
| `freezes` | 10-26, 10-29..11-22 except 11-05, 11-16 | 25, 10-29 | 28 0 0 0 | `+ . . # # # # / # # # o # # # / # # # # # # # / o # # # # # T` |
| `broken` | 11-08..11-17, 11-20..11-22 | 3, 11-20 | 28 0 0 0 | `. . . . . . . / . . . . . . + / + + + + + + + / + + . . # # T` |
| `lone` | 10-30..11-14, 11-17, 11-20..11-22 | 3, 11-20 | 28 0 0 0 | `. . . . + + + / + + + + + + + / + + + + + + . / . + . . # # T` |
| `sixty` | 09-01..09-21, 09-24..11-22 | 60, 09-24 | 22 6 0 0 | `W+ W# W# W# W# W# # / # # # # # # # / # # # # # # # / # # # # # # T` |
| `sixtyFrozen` | as `sixty` except 11-20 | 60, 09-24 | 22 6 0 0 | `W+ W# W# W# W# W# # / # # # # # # # / # # # # # # # / # # # # o # T` |
| `twoHundred` | 03-01..05-03, 05-06..11-21 | 200, 05-06 | 22 0 6 0 | `M# M# M# M# M# M# # / # # # # # # # / # # # # # # # / # # # # # # P` |
| `eightHundred` | 2024-06-01..2024-09-10, 2024-09-13..2026-11-21 | 800, 2024-09-13 | 25 0 0 3 | `Y. Y# Y# # # # # / # # # # # # # / # # # # # # # / # # # # # # P` |

Notes on the table:
- `sixty`: the first week (09-20..09-26) straddles the run's start with 3 of 7 days in it, and 5 of 7 days are
  studied, so it's `older`.
- `twoHundred`: the first month (05-01..05-31) has 26 of 31 days in the run, so it's `run`.
- `eightHundred`: the first year (2023-10-29..2024-10-28) has 148 of 366 days studied, so it's `missed`.
- The reference implementation (Python, used to build the table and the mockup) is quoted in Notes for the engineer.

Screenshots (QA, gallery, light + dark + `-theme forest`):
- `widget-gallery`;
- one cropped tile per scenario and family: `widget-small-<id>`, `widget-medium-<id>`, plus `widget-unavailable`;
- forest names end in `-forest`.

## Acceptance criteria
### API
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `GET /stats` adds `new_today` and `milestone` (exactly as spec 021 defines them), `history` (string over `s` studied, `f` frozen, `m` missed, `p` pending; one character per local day from `history_start` to today in `tz`; `p` only as the last character, when today has no review; `"p"` when there are no reviews), `history_start` (ISO date), `streak_start` (ISO date or null) and `due_new` (int, 0 ≤ `due_new` ≤ `due`) | pytest |
| 2 | Streak cases, `now` = 2026-11-21 12:00 UTC, reviews at `days_ago`: [] → 0; [0] → 1; [0,1,2] → 3; [1,2] → 2; [2] → 2 (yesterday frozen); [3] → 0; [0,1,3] → 4 (2 days ago frozen); [0,0,0] → 1; [0,1,2,4,5,6,8] → 3, `streak_start` = 2 days ago (day 7 is frozen first, so day 3, within 6 days of it, is missed) | pytest (`deck.stats`) |
| 3 | Chronological freeze: studied D−10, missed D−9, studied D−8..D−5, missed D−4, studied D−3..D0 → `history` has `f` at D−9 and `m` at D−4, `streak` 4, `streak_start` = D−3. Two misses in a row: studied D−5, missed D−4 and D−3, studied D−2..D0 → both `m`, `streak` 3 | pytest |
| 4 | Every scenario fixture (built from reviews at 10:00 local, `tz=Europe/Paris`, `now` 2026-11-22 12:00 Paris) returns the table's `streak` and `streak_start`, and a `history` matching its studied days and the freeze rule | pytest |
| 5 | 007's time-zone and DST cases (007 AC 3–5) still pass, with `history` days in the given `tz` | pytest |
| 6 | `due_new`: 3 never-reviewed cards (one held by an open report) + 2 due reviews → `due` 4, `due_new` 2 | pytest |
| 7 | MCP `deck_stats(tz)` returns the same fields. The docstring explains the freeze rule in one sentence and the `history` alphabet | pytest (MCP) + review |

### iOS
| # | Criterion (observable) | Validated by |
|---|---|---|
| 8 | `DeckStats` gains `history: String`, `historyStart: Date`, `streakStart: Date?` (both decoded as `yyyy-MM-dd` calendar days in the device zone) and `dueNew: Int`. `DecodingTests` decode a real `/stats` payload with all fields. An unknown `history` character reads as missed (forward compatible) | unit |
| 9 | `DeckStats.toReview` follows decision 9: due 64, due_new 45, new_today 19, milestone 15 → 19 + min(45, 11) = 30; due_new 0 → `due` | unit |
| 10 | `StreakGrid` returns, for every scenario, exactly the table's `D W Mo Y` and expected grid (28 marks, kinds and statuses) | unit (`DeckWidgetTests`) |
| 11 | Level thresholds: a run filling exactly 28 days → days only; 29 days → `D = 27, W = 1`; the longest weeks-level run (`D = 7, W = 21`, 154 days with today) stays in weeks and one day more goes to months; same at the months → years edge (`D = 7, Mo = 21`). Calendar maths is DST- and month-length-safe: month blocks counting back across Feb 29 (2028), the 31st, and the Paris DST change | unit |
| 12 | Grid invariants, checked over random histories (seeded): always 28 marks; kinds are non-increasing in size from oldest to newest (years, months, weeks, days); `D ≥ 7`; the last mark is today; the periods are contiguous and end today; the first period starts on or before the run's first day | unit |
| 13 | The grid's "today" is the last day of `history`: a cached stats rendered on a later day shows the same grid as when fetched | unit |
| 14 | Small widget: status line (`toReview` / "All caught up" / "No cards yet"), grid, label, as in Screens & states. Medium: left block + right grid. `.supportedFamilies([.systemSmall, .systemMedium])`; description "Your streak and cards to review." | render (#16) + review |
| 15 | Pink: in full colour, exactly one accent element per widget, today's mark (a ring when pending, filled when studied). The label is `ink` / `secondaryInk` only | render (#16, `screen-sample.py` on today's mark and the label) |
| 16 | Render suite `ScreenColorTests/WidgetRenders` (enabled only with `LA_CARTE_RENDER_DIR`, like `StudyRenders`) draws the real `DeckWidgetView` for every scenario × small/medium × light/dark/forest, plus `unavailable` and one `.accented` rendering per family, as `widget-<family>-<id>-<theme>.png` (170 × 170 / 364 × 170 pt at 3×, `Theme.background`, radius 22) | render run, attached to the QA report |
| 17 | Gallery (`LA_CARTE_SCREEN=widget`, 007 AC 23) shows every scenario in both families with the accessibility ids below | UI (light, dark, forest) |
| 18 | VoiceOver label as in Screens & states, from a pure helper (`accessibilityText(stats:)`), unit-tested for `zero`, `nine`, `three` | unit |
| 19 | `InMemoryAPIClient` returns consistent fields (`history` "s" if `reviewedToday > 0` else "p", `historyStart` today, `streak` 0/1, `dueNew` = new cards due); existing unit and UI suites stay green | unit + UI (existing) |
| 20 | On the iPhone, the small and medium widgets show the live grid; today's ring fills after a study session once the app goes to the background | **user** device check, pending in the QA report |

## TCA shape (iOS)
No reducer changes. Widget code stays plain SwiftUI + WidgetKit (007).
- **`APIClient`**:
  - the `DeckStats` fields (#8) and `toReview` (#9);
  - the live client is unchanged (it already sends `tz`);
  - `InMemoryAPIClient` (#19).
- **`DeckWidget`**:
  - `StreakGrid` (pure): `init(stats: DeckStats, calendar: Calendar)` gives `marks: [Mark]` (28, oldest first) and
    `counts` (D, W, Mo, Y). `Mark` = `unit` (`.day/.week/.month/.year`) + `status` (the table's seven cases) +
    `period` (`ClosedRange<Date>`, for tests).
  - `StreakGridView(grid:)` draws the marks with four `Shape`s (`Circle`, `RoundedRectangle`, and `Pentagon` and
    `Star` in `DeckWidget`; SF Symbols can't share one footprint and stroke).
  - `DeckWidgetView` reads `@Environment(\.widgetFamily)` and lays out small or medium.
  - The scenario fixtures live in one place (`DeckWidgetEntry.scenarios`), shared by the gallery, the renders and
    the tests.
  - "No streak yet" goes; S = 0 reads "Start a streak today".
- **Tests**:
  - `DeckWidgetTests` (#10–#13, #18);
  - `APIClientTests` (#8, #9, #19);
  - `ScreenColorTests/WidgetRenders` (#16).
- `StubAPIServer` (UI tests, qa-validator's file) adds the new fields to its `/stats` reply.

## API / MCP changes
`GET /stats?tz=Europe/Paris` (fields after 021 step 1, plus this spec):
```json
{
  "total": 120, "due": 64, "new": 45, "reviewed_today": 30, "next_due": null,
  "new_today": 19, "milestone": 15,
  "streak": 25, "streak_start": "2026-10-29",
  "history_start": "2026-10-26", "history": "smmsssssssssfssssssssssfsssss",
  "due_new": 45
}
```
(`history` here is illustrative; its length is the number of days from `history_start` to today inclusive.)
- `deck.stats`: one chronological walk over the distinct local review dates, from the first review day to today
  (decision 3), gives `history`, `streak` and `streak_start`. It replaces `_streak`. No model change, no migration:
  `ReviewLog` is kept forever (012).
- `due_new` = the queue entries whose card has `last_review IS NULL`.
- MCP `deck_stats(tz)`: same `DeckStats`, so the fields come along. The docstring adds: "`streak` forgives one
  missed day per 7 (a frozen day; two missed days in a row end it). `history`: one letter per local day since the
  first review: s studied, f frozen, m missed, p today not yet studied."

Docs to update in the implementing changes:
- `docs/architecture.md`: the `/stats` row and the MCP `deck_stats` line.
- `docs/design-system.md` (design-lead):
  - the Widget section: both families, the two mark tables, the 4 × 7 grid at a 19 pt pitch;
  - accent rule 3 → "The widget's today mark (spec 024): a 2 pt ring while today's study is still to do, filled once
    studied. The rest of the grid and the streak number are ink or grey."
- `docs/testing.md`: the `WidgetRenders` line.

## Accessibility identifiers
Gallery only (widgets aren't reachable from XCUITest):
- `widgetGallery.title`;
- `widgetGallery.tile.<family>.<id>`, with `<family>` ∈ `small`, `medium` and `<id>` from the Scenarios table;
- `widgetGallery.tile.unavailable`.

## Notes for the engineer
The table was generated by a reference implementation of the layout (and freeze walk). Port its logic; match its
output, not its style.
```python
# today: last history day; t0: streak_start or today; rd = relativedelta
for level in range(4):                      # 0 days, 1 +weeks, 2 +months, 3 +years
    for D in range(28, 6, -1):              # most days first, at least one row
        for W in (range(28 - D, -1, -1) if level >= 1 else [0]):        # then most weeks
            for Mo in (range(28 - D - W, -1, -1) if level >= 2 else [0]):  # then most months
                Y = 28 - D - W - Mo
                if Y and level < 3: continue
                first_day = today - (D - 1)
                first_week = first_day - 7 * W
                first_month = first_week - rd(months=Mo)
                first_year = first_month - rd(years=Y)
                if first_year <= t0: return Y, Mo, W, D   # periods: years, months, weeks, days
```

## Notes for QA
- Judge the visuals on the `WidgetRenders` PNGs (#16) and the gallery screenshots. Check the pink with
  `scripts/screen-sample.py`.
- Run the affected classes only (gallery UI tests), light, dark and forest. Run the full suite only if CI asks.
- #20 is the user's device check: record it as pending.

## Final design choices (2026-11-22; the manager's picks, the user didn't object)
1. **Keep the simple status rule for coarse marks.** The oldest week, month or year can straddle the history's start
   and read faint (`missed`), as `Y.` in `eightHundred`. Accepted.
2. **Keep the simple rule at the run's start too.** The oldest week can read grey (`older`) when fewer than half its
   days are in the run, as `W+` in `sixty`. Accepted.
3. **"Studied before the streak" is lighter:** `older` and `frozenOlder` use `secondaryInk` at 60% (status table),
   so the current run's `ink` marks stand out.
4. **Pentagon circumradius 5.5** (was 5.25; shapes table).

## Defaults (the user didn't object; listed so they can be revisited)
- Pink marks only today (decision 8).
- The small widget keeps "N to review" on top (decision 9).
- Freeze: one per rolling 7 days, chronological, nothing shown about freezes left (decision 3).
- Month = pentagon (the diamond was the alternative).

## Out of scope
- Lock Screen / StandBy families (backlog #14).
- A "freezes left" counter, buying or earning freezes, configurable forgiveness.
- The streak or the grid inside the app (backlog #15).
- systemLarge, interactive widgets, configurable widgets, a tap on a mark.
- Calendar-aligned weeks (Mon–Sun columns): weeks are 7-day blocks counted back from the day marks.
