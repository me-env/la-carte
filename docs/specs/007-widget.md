# 007 — Home Screen widget: cards to review + study streak

Status: ready (layout, streak rule and AC 2, 16–19 superseded by [024](024-streak-widget.md), pending the user's approval)
Owners: api-engineer (streak, step 1) → ios-engineer (contract, shared storage, widget, step 2) →
release-engineer (signing / CI for the second bundle ID, step 3)
Depends on: 001 (study, caught-up copy), 003 (server settings, `TokenStore`), 004 (themes)
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg (one thing centered-ish, quiet
meta text), 05-theme-forest.jpg (forest palette). No reference widget: we borrow the feel (paper background,
one strong number, everything else `.meta`).

## Goal
A small Home Screen widget shows, at a glance, **how many cards are due now** and **the current study streak**
(consecutive days with at least one review). Tapping it opens the app on Study. The user knows whether to open
the app without opening it.

**Why this content.** Due-now is the only number that asks for action, so it is the hero. The streak is the
motivation the user asked for and stays one quiet line. When nothing is due, the hero becomes "All caught up"
plus when the next card comes due, the same information Study shows (spec 001), so the widget never shows a
bare "0". Total/new counts are left out: they don't change what the user does.

## User stories
- As the user, I glance at my Home Screen and see "8 to review" and "12-day streak".
- As the user, when I'm caught up, the widget says so and tells me when the next card comes due.
- As the user, my streak counts every review, including the ones an agent recorded through MCP (`review_card`).
- As the user, the widget looks like the app: paper in light, charcoal in dark, deep green if I picked Forest.
- As the user, tapping the widget opens la carte on the study screen.

## Streak: definition (API, source of truth)
- A **review day** is a calendar day, **in the time zone the client sends**, with at least one row in
  `ReviewLog` (written by every review: REST `POST /cards/{id}/review` and MCP `review_card` both go through
  `deck.review_card`).
- **`streak`** = the number of consecutive review days ending **today**, or ending **yesterday** if today has no
  review yet (the streak is still alive until the end of today). Otherwise 0.
  Examples (local days): reviews today, yesterday, the day before → 3. Yesterday and the day before, none
  today → 2. Last review two days ago → 0. Several reviews on one day count once.
- **Time zone:** `GET /stats?tz=<IANA name>` (e.g. `Europe/Paris`). Day boundaries are local midnights in that
  zone, DST-correct (use `zoneinfo`). Omitted → `UTC` (today's behavior). Unknown name → **422**
  `{"detail": "Unknown time zone: <name>"}`. The same `tz` also defines **`reviewed_today`** (today it is a UTC
  day), so both numbers agree. Times in responses stay UTC.
- **Existing data:** `ReviewLog` already exists since spec 000 and is written on every review, so there is **no
  model change and no migration**: the streak is computed from history already in the database on day one.
- Known limitation (accepted): `ReviewLog.card_id` is `ON DELETE CASCADE`, so deleting a card deletes its review
  history; a day whose only reviews were of since-deleted cards no longer counts. Rare, and fixing it needs a
  table rebuild in SQLite; see backlog.

## Acceptance criteria
### API
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `GET /stats` returns `{total, due, new, reviewed_today, next_due, streak}`; `streak` is an int ≥ 0 following the definition above | pytest |
| 2 | Streak cases with an injected `now` (UTC, no `tz`): no reviews → 0; today only → 1; today+yesterday+day before → 3; yesterday+day before, none today → 2; last review two days ago → 0; today, yesterday, 3 days ago → 2 (gap stops it); three reviews today → 1 | pytest (`deck.stats`) |
| 3 | Time zone, positive offset: review at 2026-11-20T23:30Z, `now` 2026-11-21T07:00Z. `tz=Europe/Paris` → `reviewed_today` 1, `streak` 1 (it was 00:30 on the 21st in Paris); no `tz` (UTC) → `reviewed_today` 0, `streak` 1 (yesterday, still alive) | pytest |
| 4 | Time zone, negative offset: review at 2026-11-21T03:00Z (20th, 19:00 in Los Angeles), `now` 2026-11-21T20:00Z. `tz=America/Los_Angeles` → `reviewed_today` 0, `streak` 1; UTC → `reviewed_today` 1, `streak` 1 | pytest |
| 5 | DST: one review a day at 08:00 `Europe/Paris` from 2026-03-27 to 2026-03-31 (clocks change on the 29th), `now` 2026-03-31T10:00 Paris → `streak` 5 | pytest |
| 6 | A review recorded through MCP `review_card` counts: MCP review, then REST `GET /stats` → `streak` 1, `reviewed_today` 1 | pytest (MCP in-process client + REST) |
| 7 | `GET /stats?tz=Mars/Olympus` → 422 with the detail above; `GET /stats` without `tz` behaves as `tz=UTC` | pytest |
| 8 | MCP `deck_stats(tz="UTC")` returns the same `DeckStats` (incl. `streak`); an unknown `tz` returns a tool error naming the bad value; the docstring tells the agent to pass the user's IANA time zone when known | pytest (MCP) + review |

### iOS: contract and shared storage
| # | Criterion (observable) | Validated by |
|---|---|---|
| 9 | `DeckStats` gains `streak: Int`; `DecodingTests` decode a real `/stats` payload including `streak` (both existing stats tests updated) | unit |
| 10 | The live `APIClient.stats()` sends `tz=TimeZone.current.identifier`; the signature of `stats()` is unchanged. The in-memory client returns `streak = reviewedToday > 0 ? 1 : 0` | unit (InMemoryAPIClientTests) + review |
| 11 | The app and the widget share settings through App Group `group.fr.lacarte.app`: `@Shared(.appStorage)` uses `UserDefaults(suiteName: "group.fr.lacarte.app")` (via `defaultAppStorage`, set once before the first store), and the live `APIClient` reads `apiURL` from that suite | unit (APIClientTests with a temp suite) + review |
| 12 | Migration, once at launch, before the first store: `apiURL` and `theme` in `UserDefaults.standard` are copied to the App Group suite if the suite has no value for them, then removed from `.standard`. Running it twice changes nothing | unit (temp suites) |
| 13 | The token lives in the Keychain item `service "la-carte"`, `account "api-token"`, **access group `group.fr.lacarte.app`** (an App Group is a valid keychain access group, so no extra Keychain Sharing capability). Launch migration: if no shared item exists but the legacy item (same service/account, no group) does, it is moved to the shared group. `kSecAttrAccessibleAfterFirstUnlock` stays, so the widget can read it while the phone is locked | review + device check (#24) |
| 14 | Settings, Study, Deck and theme keep working exactly as before: the existing unit and UI suites pass unchanged, including `-theme forest` launch-argument screenshots (the argument domain is searched by suite defaults too; if not, the engineer reports it before working around it) | unit + UI (existing suites) |

### iOS: the widget
| # | Criterion (observable) | Validated by |
|---|---|---|
| 15 | A widget extension `LaCarteWidget` (bundle `fr.lacarte.app.widget`) ships inside the app and offers one widget, kind `DeckWidget`, display name "la carte", description "Cards to review and your streak.", family **systemSmall only** | build + review |
| 16 | State **due** (`due > 0`): hero = due count (`.cardFace`, `ink`, monospaced digits), below it "to review" (`.meta`, `secondaryInk`); bottom line = streak text | unit (entry/text) + screenshot |
| 17 | State **caught up** (`due == 0`, `next_due` non-null): hero = "All caught up" (`.body` weight medium, `ink`), below it "Next at 18:40" when `next_due` is within 24 h, otherwise "Next on 24 Nov" (localized short date) (`.meta`, `secondaryInk`); bottom line = streak text | unit + screenshot |
| 18 | State **empty deck** (`total == 0`): hero "No cards yet" (`.body` medium, `ink`), below it "Ask your agent to add some" (`.meta`, `secondaryInk`); bottom line = streak text | unit + screenshot |
| 19 | Streak text: `streak ≥ 1` → "N-day streak" (`.meta`, `ink`); `streak == 0` → "No streak yet" (`.meta`, `secondaryInk`). Long values fit: "999" due with "365-day streak" don't truncate at the default text size | unit + screenshot |
| 20 | State **unavailable**: the fetch fails and there is no cached stats → "Can't reach your deck" (`.meta`, `secondaryInk`) and nothing else. If the fetch fails but a cached stats exists (App Group key `widget.lastStats`, written by the widget after every successful fetch), the widget shows the cached stats unchanged | unit (entry from `Result` + cache) |
| 21 | Timeline: one entry per fetch; reload policy `.after(min(now + 30 min, next local midnight, next_due when due == 0))`. The app calls `WidgetCenter.shared.reloadAllTimelines()` when its scene goes to `.background` (covers reviews, edits, server and theme changes). The gallery preview (`context.isPreview`) and `placeholder` use a sample entry (8 due, 12-day streak), with no network | unit (refresh date) + review |
| 22 | Theme: the widget reads `theme` from the App Group suite. System → follows the Home Screen appearance; Light/Dark → forced; Forest → forest palette with dark scheme. Background is `Theme.background` via `containerBackground(for: .widget)`; all colors are tokens | screenshot (gallery, #23) + device check |
| 23 | Debug gallery: launching the app with `LA_CARTE_SCREEN=widget` (debug builds only, like `design-system`) shows `DeckWidgetView` in every state from fixed entries (no network), each in a 170×170 pt tile (`Theme.background`, corner radius 22, 16 pt padding, the size of a systemSmall widget on iPhone 17 Pro), under the app's current theme | UI (light, dark, `-theme forest`) |
| 24 | On the iPhone (Ad Hoc build installed **over** the previous version, with URL and token already set): the widget, added to the Home Screen, shows the live due count and streak without re-entering settings; tapping it opens the app on Study | **user** device check (manual), reported by QA as pending/confirmed |

## Screens & states
Widget layout (systemSmall, system content margins, leading-aligned, no borders, no icons):
```
┌───────────────────┐
│ 8                 │   hero      .cardFace ink  (or "All caught up" / "No cards yet", .body medium)
│ to review         │   sub       .meta secondaryInk ("Next at 18:40", "Ask your agent to add some")
│                   │
│                   │
│ 12-day streak     │   streak    .meta ink  ("No streak yet" in secondaryInk)
└───────────────────┘
```
Unavailable: only "Can't reach your deck" at the top, `.meta`, `secondaryInk`.
Tap anywhere opens the app (default widget behavior; no `widgetURL`, Study is the home).

Gallery screen (`LA_CARTE_SCREEN=widget`): title "Widget" (`.screenTitle`), then a two-column grid of tiles, each
with its state name below in `.meta`: due (8, streak 12), caught up (next at a fixed time today, streak 3),
caught up later (next in 3 days, streak 0), empty deck, unavailable, long (999 due, 365-day streak).
The tiles render `DeckWidgetView` directly with the tile background; `containerBackground` has no effect outside a
widget, so the gallery draws the same background itself.

Screenshots (gallery, light + dark + forest): `widget-gallery`, plus one per tile when cropped by
`gallery` identifiers: `widget-due`, `widget-caught-up`, `widget-caught-up-later`, `widget-empty`,
`widget-unavailable`, `widget-long`. Forest names end in `-forest` (e.g. `widget-gallery-forest`).
Device photo/screenshot of the real Home Screen widget: by the user (#24), attached to the QA report if provided.

> **Design note (design-lead, 2026-11-21, native-audit.md):** on iOS 26 a tinted or clear Home Screen renders
> widgets in `.accented` mode. Mark the hero (count / "All caught up" / "No cards yet") `.widgetAccentable()`.
> When `@Environment(\.widgetRenderingMode) != .fullColor`, use `.primary`/`.secondary` foreground styles instead of
> the ink tokens, so the text doesn't go muddy.
> **Accent (2026-11-21, user request):** the streak **number** only ("12" in "12-day streak", when streak ≥ 1) uses
> `Theme.accent` (`Text("\(n)").foregroundStyle(Theme.accent) + Text("-day streak")`). The rest of the line stays as
> in #19. In `.accented` rendering mode the number is `.widgetAccentable()` instead. Nothing else in the widget is pink. Add an "accented" tile to the gallery if it's cheap; otherwise QA
> checks it on the device (#24). No other change.

## TCA shape (iOS)
No reducer changes. The widget is plain SwiftUI + WidgetKit (no TCA, like `DesignSystem`).

**New module `DeckWidget`** (library product `DeckWidget`, deps: `APIClient`, `DesignSystem`; imports WidgetKit;
no ComposableArchitecture):
- `DeckWidgetEntry: TimelineEntry` = `date` + `content: Content`, `enum Content: Equatable { case stats(DeckStats), unavailable }`.
- Pure functions (unit-tested in `DeckWidgetTests`): `Content.make(result: Result<DeckStats, any Error>, cached: DeckStats?)`,
  `nextRefresh(stats: DeckStats?, now: Date, calendar: Calendar) -> Date`, and the text helpers
  (`streakText`, `nextDueText(now:calendar:)`), all with injected `now`/`calendar`/`locale` where relevant.
- `DeckWidgetProvider: TimelineProvider`: calls `APIClient.liveValue.stats()` (no launch env in an extension, so
  it resolves from the App Group + Keychain), writes `widget.lastStats` (JSON `DeckStats`) on success.
- `DeckWidgetView(entry:)` + `DeckWidget: Widget` (`StaticConfiguration`, kind `"DeckWidget"`), and
  `DeckWidgetGallery` (debug screen, #23). `#Preview(as: .systemSmall)` for each state.
- Theme helper: a modifier applying `\.appTheme` and, for light/dark/forest, `\.colorScheme`, placed **outside**
  `containerBackground` so the background token resolves with it.

**`APIClient` module**: `AppGroup` (`id = "group.fr.lacarte.app"`, `defaults`), the defaults migration (#12), the
Keychain access group + migration in `TokenStore` (#13), `DeckStats.streak`, `tz` query in `live`.
`AppTheme`'s storage key `"theme"` gets one constant (e.g. `AppTheme.storageKey` in `DesignSystem`) used by the
`.theme` shared key and the widget.

**`AppFeature`**: `RootView` routes `LA_CARTE_SCREEN=widget` to `DeckWidgetGallery`, and observes `scenePhase`
to call `WidgetCenter.shared.reloadAllTimelines()` on `.background` (a side effect with no state; kept in the
view on purpose). A public `bootstrap()` (or equivalent) in `AppFeature` sets `defaultAppStorage` to the App
Group suite and runs both migrations; the app shell calls it once in `LaCarteApp.init()` (one line).

**Xcode project** (`ios-engineer` may edit `project.pbxproj` because a target is added):
- New target `LaCarteWidgetExtension` (app extension, `com.apple.widgetkit-extension`), synchronized folder
  `ios/LaCarteWidget/` holding only `@main struct LaCarteWidgets: WidgetBundle { DeckWidget() }`, links the
  `DeckWidget` product, deployment target iOS 26.0, team 5X9ZWT7KT3, embedded in the app ("Embed Foundation
  Extensions"). Keep `objectVersion = 77`.
- Entitlements: `ios/Config/LaCarte.entitlements` and `ios/Config/LaCarteWidget.entitlements`, each with
  `com.apple.security.application-groups = [group.fr.lacarte.app]`.

**Tests**: `DeckWidgetTests` (content from result/cache, refresh date incl. midnight and `next_due` cases, text
helpers incl. "Next at"/"Next on" and 1-day/0-day streak), `APIClientTests` (decoding, migration with temp suites,
in-memory streak). Existing TestStore suites must stay green unchanged.

## Signing & release (release-engineer)
- **Forks / signing scheme** (added after this spec): team and bundle IDs come from `ios/Config/Signing.xcconfig`
  (see `docs/release.md`, "Your own team"). Read `fr.lacarte` below as `$(LA_CARTE_BUNDLE_ID_PREFIX)`: the widget
  target uses that xcconfig as base configuration, `PRODUCT_BUNDLE_IDENTIFIER = $(LA_CARTE_BUNDLE_ID_PREFIX).app.widget`,
  no `DEVELOPMENT_TEAM` in the target; entitlements list `group.$(LA_CARTE_BUNDLE_ID_PREFIX).app`; and `AppGroup.id`
  is read at runtime from an Info.plist key with that value (both app and widget), not hard-coded.
- The Ad Hoc build now signs **two** bundle IDs: `fr.lacarte.app` and `fr.lacarte.app.widget`, both with the App
  Group `group.fr.lacarte.app`. Automatic signing with `-allowProvisioningUpdates` + the ASC API key registers the
  new App ID, the App Group, and both Ad Hoc profiles; no change to `ExportOptions-AdHoc.plist` expected
  (automatic, no per-bundle profile map). If the API key can't register the App Group, the user creates it once at
  developer.apple.com (Identifiers → App Groups) — flag it, don't do it without the user's OK.
- `ci/verify-ipa.sh` also checks `Payload/LaCarte.app/PlugIns/LaCarteWidgetExtension.appex`: valid signature, Ad
  Hoc profile, and that **both** embedded entitlements contain `group.fr.lacarte.app`.
- Simulator builds (`scripts/ios-*.sh`, CI) must keep working without an Apple account: verify the extension and
  the App Group entitlement don't require a provisioning profile for the simulator.
- Update `docs/release.md` (two bundle IDs, App Group).

## API / MCP changes
`deck.stats(session, now=None, tz: ZoneInfo = UTC)`: `reviewed_today` uses local day bounds in `tz`; new `streak`.
Streak algorithm: iterate `ReviewLog.reviewed_at` newest first, map to local dates, stop at the first gap (or when
the newest day is before yesterday). Add `tzdata` to dependencies so `zoneinfo` works in the slim Docker image.

`GET /stats?tz=Europe/Paris` →
```json
{"total": 42, "due": 8, "new": 3, "reviewed_today": 5, "next_due": "2026-11-21T17:40:00Z", "streak": 12}
```
Unknown `tz` → 422 `{"detail": "Unknown time zone: Mars/Olympus"}`.

MCP `deck_stats(tz: str = "UTC") -> DeckStats`. Docstring adds: "`streak`: consecutive days with at least one
review, ending today or yesterday, in `tz`. Pass the user's IANA time zone (e.g. `Europe/Paris`) when you know it;
`reviewed_today` and `streak` use it."

Docs to update in the implementing change: `docs/architecture.md` (REST `/stats` row with `tz` + `streak`, MCP
`deck_stats(tz)`, iOS tree with `LaCarteWidget/` and the `DeckWidget` module, App Group storage replacing
"`UserDefaults` key `apiURL`" and the Keychain note), `docs/design-system.md` (Widget section: layout above,
tile size, gallery), `docs/testing.md` (`LA_CARTE_SCREEN=widget`), `docs/release.md` (signing, above).

## Accessibility identifiers
Widgets are not reachable from XCUITest; identifiers are for the gallery only:
- `widgetGallery.title`
- `widgetGallery.tile.<state>` (`due`, `caughtUp`, `caughtUpLater`, `empty`, `unavailable`, `long`): each tile
  container, for cropped screenshots.
Widget VoiceOver: the widget combines into one element reading e.g. "8 cards to review, 12-day streak" /
"All caught up, next at 18:40, 12-day streak".

## Notes for QA
- Validate the widget through the gallery (`LA_CARTE_SCREEN=widget`, mock not needed but harmless) in light,
  dark, and `-theme forest`, at default text size; plus pytest/unit results for #1–#13, #15–#21.
- Regression: rerun the full mock UI suite and `scripts/e2e.sh` (storage moved to the App Group; #14).
- Adding the widget to the Simulator Home Screen via Springboard automation is optional, best effort, non-blocking.
- #24 is a manual check by the user on the iPhone; record it as pending in the report unless the user confirms.

## Out of scope
- Lock Screen / StandBy accessory widgets (`accessoryCircular`, `accessoryRectangular`), medium/large sizes.
- Showing the streak inside the app.
- Interactive widgets (rating from the widget), deep links other than opening the app, configurable widgets.
- Tuning for tinted / clear Home Screen rendering modes beyond staying readable.
- Preserving review history when a card is deleted (cascade, see definition).
- Push-based widget refresh from the server.
