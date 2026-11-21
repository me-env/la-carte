# Backlog

Ordered. The architect turns items into specs; the manager starts every `ready` item whose files don't overlap
work in flight (one git worktree per engineer instance). Groomed 2026-11-21.

## Lanes now (what can run in parallel)

| Lane | In flight | Next (ready) | Files (stay apart) |
|---|---|---|---|
| iOS: widget | 007 widget (ios-engineer, worktree) | #14 Lock Screen widgets (spec when 007 lands) | widget extension, App Group, `APIClient` stats |
| iOS: Study | 010 inline edit (ios-engineer, worktree) | 011 ratings → 009c Study polish → 013 step 2 | `StudyFeature/**` (strictly one at a time) |
| iOS: Deck | — | **009a** Deck sheet | `DeckFeature/**` |
| iOS: sheets | — | **009b** Editor + Settings sheets | `CardEditorFeature/**`, `SettingsFeature/**` |
| Design | logo round 9 (design-lead, design-critic) | 009b #7–#8 (`CircleIconButton` glass, `LaunchBackground`); 011 design notes | `DesignSystem/**`, `ios/LaCarte/Assets.xcassets`, `ios/Config/Info.plist` |
| API | — | **012** keep review history → 013 step 1 | `api/**` (012 before 013: same table) |
| Process | CI/CD (cicd-lead), tooling loops (tooling-lead) | — | `ci/`, `.github/`, `scripts/` |

## Items

| # | Item | Notes | Status | Owner | Spec |
|---|---|---|---|---|---|
| 0 | Walking skeleton: app ↔ API ↔ MCP, test & screenshot pipeline | Done during setup | done | — | 000 |
| 1 | **Study session**: due cards one by one, front → tap to reveal back → rate again/hard/good/easy | Core loop. Home *is* the study screen (Vyst editor layout) | done | — | 001 |
| 2 | **Empty / caught-up state**: "All caught up", next due time | Part of study screen | done | — | 001 |
| 3 | **Deck list**: all cards, search, swipe to delete | Vyst notes list (04) | done | — | 002 |
| 4 | **Add / edit card**: sheet with front + back | Vyst detail (03) | done | — | 002 |
| 5 | **Server settings**: API URL + token on device (Keychain), connection check | Needed for real-device use | done | — | 003 |
| 6 | **Deploy API**: hosting, HTTPS, token | Dokploy, `docs/deploy.md`; deploys gated on tests | done | cicd-lead | |
| 7 | Themes (light / dark / forest) | `@Shared(.appStorage)` | done | — | 004 |
| 8 | MCP prompts: "quiz me", "make cards from this text" | Agent ergonomics | done | — | 005 |
| 9 | Offline review queue | Only if needed: no user report of it yet | deferred | — | |
| 10 | Undo last rating (`arrow.uturn.backward` on study) | Split from 001. Needs an API undo (restore the card's previous FSRS state + drop the log row): spec after 011, touches Study | backlog | architect | |
| 11 | **Refresh**: pull-to-refresh on study + deck, reload on return to foreground | Split from 001 | done | — | [006](006-refresh.md) |
| 12 | Deck pagination beyond 500 cards | Split from 002. Deferred: one personal deck, search is server-side over all cards; revisit when a deck nears 500 | deferred | — | |
| 13 | **Widget**: Home Screen systemSmall, due-now count + study streak | API part merged (`/stats?tz=`, streak); iOS part in a worktree | in-progress | ios-engineer | [007](007-widget.md) |
| 14 | Lock Screen widgets (accessoryCircular due count, accessoryRectangular due + streak) | Split from 007. Spec once 007 merges; widget-extension files only, parallel to everything else | backlog | architect → ios-engineer | |
| 15 | Show the streak in the app (caught-up screen) | Split from 007. Study files: after 009c | backlog | architect → ios-engineer | |
| 16 | Keep review history when a card is deleted | No FK on `ReviewLog.card_id` + startup table rebuild. API only, start now | ready | api-engineer | [012](012-keep-review-history.md) |
| 17 | **Setup state**: "Connect your deck", "Token rejected", no localhost default | User feedback from first iPhone install | done | — | [008](008-setup.md) |
| 18 | **Inline edit**: double-tap the revealed front/back to fix it in place | User request | in-progress | ios-engineer | [010](010-inline-edit.md) |
| 19 | Cancel / undo an inline edit (hardware Escape, shake to undo) | Split from 010. Study files: after 011 | backlog | — | |
| 20 | **Ratings**: Forgot / Got it buttons + confidence-dots drag | User request. Starts when 010 merges; design-lead notes first | ready | ios-engineer (design-lead notes) | [011](011-ratings.md) |
| 21 | Rating-drag extras: flick commit, hysteresis, first-run hint | Split from 011. Study files: after 011 | backlog | — | |
| 22 | Store the continuous confidence (0–1) with each review | API step after 012; iOS step after 011 (not alongside 009c) | ready | api-engineer → ios-engineer | [013](013-review-confidence.md) |
| 23 | **Native polish: Deck sheet** (large title, `.searchable`, `ContentUnavailableView`, context menu, haptics) | From 009 (design-lead draft). Start now | ready | ios-engineer | [009a](009a-native-deck.md) |
| 24 | **Native polish: Editor + Settings sheets** (toolbar Save/Close, discard dialog, `Form`), launch background, glass `CircleIconButton` | From 009. Start now; design-lead does #7–#8 in parallel | ready | ios-engineer + design-lead | [009b](009b-native-sheets.md) |
| 25 | **Native polish: Study** (`ContentUnavailableView`, counter tick, loading mark, reveal/rate haptics) | From 009. After 011 | ready (blocked on 011) | ios-engineer | [009c](009c-native-study.md) |
| 26 | Logo / brand (round 9) | Animatable `LaCarteLogo`, app icon follow-up | in-progress | design-lead, design-critic | |
