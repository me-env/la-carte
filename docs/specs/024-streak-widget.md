# 024 — Widget: the streak as a dot grid (with freezes)

Status: draft (awaiting the user's approval; then `ready`)
Owners: api-engineer (step 1: `/stats` fields, freeze rule) → ios-engineer (step 2: contract, grid, widget,
renders) → qa-validator. design-lead updates `docs/design-system.md` (Widget section, accent rule 3) with step 2.
Depends on: 007 (widget, merged), 021 step 1 (`new_today`, `milestone` on `/stats`; same `api/**` lane, do it first).
Replaces in 007: the widget layout, AC 2 (streak cases), AC 16–19 and the gallery tiles. Everything else in 007
(App Group, Keychain, provider, cache, refresh, theme, signing) stays. Settles backlog #46.
Design reference: the design-lead mockup (2026-11-22, not a real render)
`docs/design/renders/024/streak-widget-mockup.png`; feel from 02-editor-light.jpg / 01-editor-dark.jpg (quiet,
one thing at a time) and 05-theme-forest.jpg.

## Goal
User feedback (2026-11-22): "The widget just showing a two-day streak does not motivate anyone to continue. Can we
instead have something like the GitHub contribution thing: a line of grey dots representing days, the last ones the
most recent days, coloured if you worked that day. You can see the streak by counting [...]. If you go past the
number of dots a line can show, it spawns another line [...]. Then another kind of dot represents a week [...]. Each
time you reach the limit of dots shown on screen, it goes up another layer: then it's months, and then years."
Plus a user decision: a **forgiving streak**. One missed day now and then is saved ("frozen") instead of breaking
the streak, and the widget shows it differently from studied and missed days.

After this ships, the widget shows the streak as dots you can count, today's dot says whether today is still to do,
and a long streak "levels up" to week, month and year marks.

## User stories
- As the user, I see three dark dots ending in a pink one and know I have a 3-day streak and studied today.
- As the user, I see a pink ring at the end of my dots and know today is still to do.
- As the user, I missed one day last week and my streak survived: that day is a hollow ring, not a gap.
- As the user, after a month of studying my rows of days became week dots, and later month and year marks.
- As the user, the number on the widget matches the counter in Study.

## Decisions
1. **A studied day** = a local calendar day with at least one review (any rating, REST or MCP), as in 007. Showing up
   is what counts. Thresholds like "finished all due cards" or "reached a milestone" were rejected: harder to
   explain, and they punish busy days.
2. **Time zone**: the `tz` the app already sends to `/stats` (device zone, 007). Day boundaries are local midnights,
   DST-correct. Travelling re-buckets past reviews into the new zone's days. That's accepted, as in 007.
3. **Freeze rule (auto, nothing to buy or earn).** Walk the local days chronologically, from the first review day
   to yesterday. A missed day *x* is **frozen** when all three hold:
   - the day before *x* is studied;
   - no frozen day lies in the 6 days before *x* (so at most one freeze in any 7 consecutive days);
   - the day after *x* is studied, or is today (studied or not yet).

   Any other missed day is **missed** and ends the run. So two missed days in a row always break the streak; neither
   is shown frozen. Freezes don't accumulate, and there's no counter of "freezes left". The walk is chronological
   (a freeze is spent when the day is missed), so of two misses 4 days apart, the **later** one breaks the run.

   A missed yesterday is frozen provisionally while today is open: if today ends without a review, tomorrow's walk
   sees two missed days in a row and the run breaks.
4. **Streak** `S` = the number of days in the current run, frozen days included. The run ends today if today is
   studied, otherwise yesterday. Today, not yet studied, is **pending**: neither counted nor missed. So the dots in
   the run are the streak: count them. `streak_start` is the run's first day, or null when `S = 0`.
   Changes vs 007: today, yesterday and 3 days ago (2 days ago missed) was 2 and is now 4. A last review 2 days ago
   was 0 and is now 2 (yesterday frozen). A last review 3 days ago is still 0.
5. **Data from the server: the facts, not the layout.** `/stats` gains `streak_start`, the last 28 local days with a
   status each, and `due_new` (decision 9). The grid layout (layers, rows) is display maths and lives in the widget.
   No scheduling is involved. 28 = the day layer's capacity (4 rows × 7). The coarse layers need only the last ≤ 7
   days plus `streak` and `streak_start`.
6. **The widget's "today" is the last date in `recent_days`**, never the device clock. A cached response
   (`widget.lastStats`, 007) then renders exactly as it was fetched. The refresh at local midnight (007 AC 21) keeps it
   current.
7. **Families: systemSmall and systemMedium**, one widget kind (`DeckWidget`). Lock Screen stays backlog #14.
8. **Pink = today.** Today's dot is the widget's only accent: a ring while today is still to do, filled once
   studied. The streak number becomes `ink`. A run of pink dots would be a pink fill, which the accent rule forbids.
   This replaces accent rule 3 in `docs/design-system.md`.
9. **The count (#46): the widget shows Study's number.** Since 021 v2, `stats.due` includes every new card, so
   "300 to review" is possible. The widget shows the counter Study shows (021 decision 6), from `/stats` alone:
   `toReview = (due − due_new) + min(due_new, milestone − new_today % milestone)`.
   `due_new` (new field) = the never-reviewed cards in the servable queue (a subset of `due`). The function is
   `DeckStats.toReview` in `APIClient`. Study's batch is capped at 100, so the two can differ only when more than 100
   cards are due. That's accepted.

## The grid (rules; `StreakGrid`, pure, unit-tested)
**Input:** `streak`, `streak_start`, `recent_days` (today = its last date), a Gregorian `Calendar` in the device
time zone. **Output:** rows of dots, top to bottom, each row ≤ 7 dots, at most **R = 4 rows** (both families).
Reading order is left to right, top to bottom; the newest is last. Partial rows are left-aligned. The grid is
bottom-anchored: rows grow upward, so today's row sits in the same place every day.

`S' = S + (today pending ? 1 : 0)`: the run plus today's slot.

**Layer choice** (the first that fits):
1. **Days**, if `S' ≤ 28`. `rows = max(1, ceil(S'/7))`. The grid is the last `rows × 7` calendar days, ending
   with today in the last slot. Each slot shows its day's status (table below). Days before `streak_start` are
   "older".
2. **Weeks**, if `W = S div 7 ≤ 21`. `W` week dots (wrapping every 7), then the **day row**.
3. **Months**, if `Mo ≤ 14`. `Mo` = full calendar months from `streak_start`: the largest n with
   `streak_start + n months ≤ runEnd + 1 day`. The rest of the run, `r` days, splits into `w = r div 7` weeks and
   `d = r mod 7` days. Rows: `Mo` month dots, `w` week dots (the row is omitted when `w = 0`), then the day row.
4. **Years**, otherwise. `Y` full calendar years, then `m` months (≤ 11), then `w` weeks and `d` days, as above.
   Rows: years, months, weeks (each omitted when 0), then the day row.

Each coarse unit starts its own row and wraps every 7. If that needs more than 3 rows (it can happen in the year
layer, e.g. 8+ months and 1+ week), the coarse dots instead flow as one sequence, biggest first, wrapping every 7.

**The day row** (layers 2–4) is the current week in progress, a 7-slot progress track:
- first the last `d` run days, with their statuses (`d = S mod 7` in the week layer);
- then today's pending ring, if today isn't studied;
- then "not yet" slots up to 7.

Freezes inside a completed week, month or year don't show: a coarse dot is just done. When `d = 0` and today is
studied, today has just completed a unit, so the row is all "not yet" and no pink shows. That's accepted.

**Unit marks: pending the user's pick (2026-11-22).** The user rejected size as the unit cue ("feels more like a UI
bug than a feature") and wants a shape per unit, all the same size. Mockups in `docs/design/renders/024/`:
- `marks-A-letters.png`: variant A, the letters D / W / M / Y. The critic gave it 4/10 and design-lead advises against it.
- `marks-B-shapes-pentagon.png`: variant B, recommended. Day circle, week rounded square, month pentagon, year star.
  All have the same ink area (about 64 pt²). Frozen is the same shape, hollow.
- `marks-B-shapes-diamond.png`: variant B with a diamond month.
- `marks-B-month-compare.png`: the pentagon and the diamond side by side.

Once the user picks, the week / month / year rows of the table below are replaced by the chosen marks.

**Dots** (design-lead, mockup v4; superseded for week / month / year by the pick above). The grid pitch is 19 pt; the grid is 133 pt wide and at most 76 pt tall.

| Dot | Shape | Full colour (all themes, tokens) |
|---|---|---|
| day, studied, in the run | circle Ø 9 | `ink` fill |
| day, studied, older than the run | circle Ø 9 | `secondaryInk` fill |
| day, frozen, in the run | ring Ø 9, 1.5 pt | `ink` stroke, hollow |
| day, frozen, older | ring Ø 9, 1.5 pt | `secondaryInk` stroke |
| day, missed | circle Ø 9 | `secondaryInk` 35% fill |
| today, pending | ring Ø 9, 2 pt, over a Ø 9 fill | `accent` stroke over `secondaryInk` 35% |
| today, studied | circle Ø 9 | `accent` fill |
| not yet (day row, layers 2–4) | circle Ø 4 | `secondaryInk` 35% fill |
| week | circle Ø 11 | `ink` fill |
| month | circle Ø 13 | `ink` fill |
| year | rounded square 13, radius 3 | `ink` fill |

Tinted/clear Home Screens (`widgetRenderingMode != .fullColor`):
- the today dot is `.widgetAccentable()`;
- `ink` becomes `.primary`, and `secondaryInk` (35% included) becomes `.secondary`;
- frozen and today stay distinct by shape (a thin hollow ring vs a ring over a fill).

## Screens & states
**systemSmall** (system content margins, leading-aligned, `Theme.background` via `containerBackground`):
```
┌───────────────────┐
│ 8 to review       │  status   .body medium ink: "N to review" (toReview) / "All caught up" / "No cards yet"
│                   │
│ ● ● ● ● ● ● ●     │  grid     bottom-anchored, ≤ 4 rows
│ ● ● ● ○ ● ● ◎     │           (today's row 8 pt above the label)
│ 9-day streak      │  label    .meta semibold ink "N-day streak"; S = 0: "Start a streak today" .meta secondaryInk
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
all caught up". The dots are decorative.

**Scenarios** (fixtures; today = Sun 2026-11-22; no reviews other than those listed; the same set for unit tests, renders and the gallery):

| id | Fixture | Expected grid | Label |
|---|---|---|---|
| `zero` | no reviews ever | days, 1 row: 6 missed, today pending | Start a streak today |
| `three` | studied 11-20..11-22 | days, 1 row: 4 missed, 2 run, today studied | 3-day streak |
| `nine` | studied 11-13..11-21, today pending | days, 2 rows: 4 missed, 9 run, today pending | 9-day streak |
| `freezes` | studied 10-26, 10-29..11-22 except frozen 11-05 and 11-16 | days, 4 rows: 1 older studied, 2 missed, 25 run (frozen at run days 8 and 19), today studied | 25-day streak |
| `broken` | studied 11-08..11-17, missed 11-18 and 11-19, studied 11-20..11-22 | days, 1 row: 2 older studied, 2 missed, 2 run, today studied | 3-day streak |
| `sixty` | 60 days, start 09-24, today studied | weeks: 8 week dots (7 + 1); day row: 3 run, today studied, 3 not yet | 60-day streak |
| `twoHundred` | 200 days, start 05-06, today pending | months: 6 month dots, 2 week dots; day row: 2 run, today pending, 4 not yet | 200-day streak |
| `fourHundred` | 400 days, start 2025-10-19, today studied | months: 13 month dots (7 + 6), no week row; day row: 3 run, today studied, 3 not yet | 400-day streak |
| `eightHundred` | 800 days, start 2024-09-13, today pending | years: 2 year marks, 2 month dots, 1 week dot; day row: 2 run, today pending, 4 not yet | 800-day streak |

Screenshots (QA, gallery, light + dark + `-theme forest`):
- `widget-gallery`;
- one cropped tile per scenario and family: `widget-small-<id>`, `widget-medium-<id>`, plus `widget-unavailable`;
- forest names end in `-forest`.

## Acceptance criteria
### API
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `GET /stats` adds `streak_start` (local ISO date or null), `recent_days` (exactly 28 `{date, status}` objects, oldest first, the last one today in `tz`) and `due_new` (int, 0 ≤ `due_new` ≤ `due`). `status` ∈ `studied`, `frozen`, `missed`, `pending`; `pending` only for today, when today has no review | pytest |
| 2 | Streak cases, `now` = 2026-11-21 12:00 UTC, reviews at `days_ago`: [] → 0; [0] → 1; [0,1,2] → 3; [1,2] → 2; [2] → 2 (yesterday frozen); [3] → 0; [0,1,3] → 4 (2 days ago frozen); [0,0,0] → 1; [0,1,2,4,5,6,8] → 3, `streak_start` = 2 days ago (day 7 frozen first, so day 3, within 6 days of it, is `missed`) | pytest (`deck.stats`) |
| 3 | Chronological freeze: studied D−10, missed D−9, studied D−8..D−5, missed D−4, studied D−3..D0 → D−9 `frozen`, D−4 `missed`, `streak` 4, `streak_start` = D−3. Two misses in a row: studied D−5, missed D−4 and D−3, studied D−2..D0 → both `missed`, `streak` 3 | pytest |
| 4 | Each fixture in the Scenarios table (built from reviews, `tz=Europe/Paris`, `now` 2026-11-22 10:00 Paris) returns the listed `streak`, `streak_start` and day statuses (`zero`: all `missed` + today `pending`, `streak_start` null) | pytest |
| 5 | 007's time-zone and DST cases (007 AC 3–5) still pass, with `recent_days` dates in the given `tz` | pytest |
| 6 | `due_new`: 3 never-reviewed cards (one of them held by an open report) + 2 due reviews → `due` 4, `due_new` 2 | pytest |
| 7 | MCP `deck_stats(tz)` returns the same fields. The docstring explains the freeze rule in one sentence and says `recent_days` covers the last 28 local days | pytest (MCP) + review |

### iOS
| # | Criterion (observable) | Validated by |
|---|---|---|
| 8 | `DeckStats` gains `streakStart: Date?` (local date, decoded as a `yyyy-MM-dd` calendar day), `recentDays: [StreakDay]` (`date`, `status: .studied/.frozen/.missed/.pending`) and `dueNew: Int`. `DecodingTests` decode a real `/stats` payload with all fields, and an unknown `status` decodes as `.missed` (forward compatible) | unit |
| 9 | `DeckStats.toReview` follows decision 9: due 64, due_new 45, new_today 19, milestone 15 → 19 + min(45, 11) = 30; due_new 0 → `due` | unit |
| 10 | `StreakGrid` returns the expected layer and rows for every scenario in the table, and for these thresholds: S' = 28 → days, 4 rows; S = 29 → weeks (4 week dots + day row); W = 21 → weeks; W = 22 → months; Mo = 14 → months; Mo = 15 → years; a year-layer case with 8 months and 1 week flows the coarse dots as one sequence (≤ 3 rows) | unit (`DeckWidgetTests`) |
| 11 | Calendar maths is DST- and month-length-safe: months follow `start + n months ≤ runEnd + 1 day` with Foundation's month clamping (a run starting Jan 31 has 1 month once Feb 28 is in the run); tested for a Jan 31 start, a Feb 29 start (2028) and a run across the Paris DST change | unit |
| 12 | The grid's "today" is the last date of `recentDays`: a cached stats rendered on a later day shows the same grid as when fetched | unit |
| 13 | Small widget: status line (`toReview` / "All caught up" / "No cards yet"), grid, label, as in Screens & states; medium: left block + right grid. `.supportedFamilies([.systemSmall, .systemMedium])`; description "Your streak and cards to review." | render (#15) + review |
| 14 | Pink: in full colour, exactly one accent element per widget, the today dot (ring when pending, fill when studied), none when `d = 0` in a coarse layer. The label is `ink` / `secondaryInk` only | render (#15, `screen-sample.py` on the today dot and label) |
| 15 | Render suite `ScreenColorTests/WidgetRenders` (enabled only with `LA_CARTE_RENDER_DIR`, like `StudyRenders`) draws the real `DeckWidgetView` for every scenario × small/medium × light/dark/forest, plus `unavailable` and one `.accented` rendering per family, as `widget-<family>-<id>-<theme>.png` (170 × 170 / 364 × 170 pt at 3×, `Theme.background`, radius 22) | render run, attached to the QA report |
| 16 | Gallery (`LA_CARTE_SCREEN=widget`, 007 AC 23) shows every scenario in both families with the accessibility ids below | UI (light, dark, forest) |
| 17 | VoiceOver label as in Screens & states, from a pure helper (`accessibilityText(stats:)`), unit-tested for `zero`, `nine`, `three` | unit |
| 18 | `InMemoryAPIClient` returns consistent fields (today `studied` if `reviewedToday > 0`, else `pending`; 27 earlier days `missed`; `streak` 0/1; `dueNew` = new cards due); existing unit and UI suites stay green | unit + UI (existing) |
| 19 | On the iPhone, the small and medium widgets show the live grid; today's ring fills after a study session once the app goes to the background | **user** device check, pending in the QA report |

## TCA shape (iOS)
No reducer changes. Widget code stays plain SwiftUI + WidgetKit (007).
- **`APIClient`**: `DeckStats` fields (#8) and `toReview` (#9); `StreakDay`; live client unchanged (it already sends
  `tz`); `InMemoryAPIClient` (#18).
- **`DeckWidget`**:
  - `StreakGrid` (pure): `init(stats: DeckStats, calendar: Calendar)` → `layer: Layer` (`.days/.weeks/.months/.years`)
    and `rows: [[Dot]]`. `Dot` is an enum of the table's kinds.
  - `StreakGridView(grid:)` draws it.
  - `DeckWidgetView` takes `@Environment(\.widgetFamily)` and lays out small/medium.
  - The scenario fixtures live in one place (`DeckWidgetEntry.scenarios`), shared by the gallery, the renders and
    the tests.
  - Remove `streakText`'s "No streak yet" (now "Start a streak today").
- **Tests**: `DeckWidgetTests` (#10–#12, #17), `APIClientTests` (#8, #9, #18), `ScreenColorTests/WidgetRenders` (#15).
- `StubAPIServer` (UI tests, qa-validator's file) adds the new fields to its `/stats` reply.

## API / MCP changes
`GET /stats?tz=Europe/Paris` (fields after 021 step 1, plus this spec):
```json
{
  "total": 120, "due": 64, "new": 45, "reviewed_today": 30, "next_due": null,
  "new_today": 19, "milestone": 15,
  "streak": 25, "streak_start": "2026-10-29",
  "due_new": 45,
  "recent_days": [
    {"date": "2026-10-26", "status": "studied"},
    {"date": "2026-10-27", "status": "missed"},
    "... 28 entries, oldest first ...",
    {"date": "2026-11-05", "status": "frozen"},
    {"date": "2026-11-22", "status": "studied"}
  ]
}
```
- `deck.stats`: one chronological walk over the distinct local review dates (from the first review day to today)
  gives every day's status, `streak` and `streak_start` (decision 3). It replaces `_streak`. No model change, no
  migration: `ReviewLog` is kept forever (012).
- `due_new` = the queue entries whose card has `last_review IS NULL`.
- Constant `RECENT_DAYS = 28` in `deck.py`.
- MCP `deck_stats(tz)`: same `DeckStats`, so the fields come along. The docstring adds: "`streak` forgives one missed
  day per 7 (a 'frozen' day; two missed days in a row end it). `recent_days`: the last 28 local days, each studied,
  frozen, missed or pending (today)."

Docs to update in the implementing changes:
- `docs/architecture.md`: the `/stats` row and the MCP `deck_stats` line.
- `docs/design-system.md` (design-lead):
  - the Widget section: both families, the dot table, R = 4, the 19 pt pitch;
  - accent rule 3 → "The widget's today dot (spec 024): a 2 pt ring while today's study is still to do, filled once
    studied. The rest of the streak grid and the streak number are ink."
- `docs/testing.md`: the `WidgetRenders` line.
- Spec 007's header points here (done in this change).

## Accessibility identifiers
Gallery only (widgets aren't reachable from XCUITest):
- `widgetGallery.title`;
- `widgetGallery.tile.<family>.<id>`, with `<family>` ∈ `small`, `medium` and `<id>` from the Scenarios table;
- `widgetGallery.tile.unavailable`.

## Notes for QA
- Judge the visuals on the `WidgetRenders` PNGs (#15) and the gallery screenshots. Check the pink with
  `scripts/screen-sample.py`.
- Run the affected classes only (gallery UI tests), light, dark and forest. Run the full suite only if CI asks.
- #19 is the user's device check: record it as pending.

## Out of scope
- Lock Screen / StandBy families (backlog #14; the grid's day row could suit `accessoryRectangular` later).
- A visible "freezes left" counter, buying or earning freezes, configurable forgiveness.
- The streak or the grid inside the app (backlog #15).
- Showing older history beyond what the layer needs (e.g. a minimum of 2 day rows to show a broken run): open
  choice for the user.
- systemLarge, interactive widgets, configurable widgets.
- Calendar-aligned weeks (Mon–Sun columns): weeks are run-relative (`S div 7`).
