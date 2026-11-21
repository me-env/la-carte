# Backlog

Ordered. The architect turns items into specs; the manager starts every `ready` item whose files don't overlap
work in flight (one git worktree per engineer instance). Groomed 2026-11-21.

## Lanes now (what can run in parallel)

| Lane | In flight | Next (ready) | Files (stay apart) |
|---|---|---|---|
| iOS: widget / client | 007 widget (ios-engineer, worktree) | **014b** notes `APIClient` (needs 007 merged) → #14 Lock Screen widgets | widget extension, App Group, `APIClient/**` |
| iOS: Study | 010 inline edit (QA), 011 ratings (worktree) | **014d** notes in Study, 009c Study polish, 013 step 2 (manager picks order; all need 011) | `StudyFeature/**` (strictly one at a time) |
| iOS: Deck | 009a Deck sheet (worktree) | **014c** notes deck + editor (needs 014b, 009a, 009b) | `DeckFeature/**` |
| iOS: sheets | 009b Editor + Settings (worktree) | 014c (same lane as Deck once 009a/009b land) | `CardEditorFeature/**` (→ `NoteEditorFeature`), `SettingsFeature/**` |
| Design | logo round 9 (design-lead, design-critic) | 014c + 014d design notes (person editor, photo on the card face): **start now**; 009b #7–#8; 011 design notes | `DesignSystem/**`, `ios/LaCarte/Assets.xcassets`, `ios/Config/Info.plist` |
| API | — | **013 step 1** → **014a** notes API + MCP + migration → **015a** reports | `api/**` (same files: one after the other) |
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
| 16 | Keep review history when a card is deleted | No FK on `ReviewLog.card_id` + startup table rebuild | done | api-engineer | [012](012-keep-review-history.md) |
| 17 | **Setup state**: "Connect your deck", "Token rejected", no localhost default | User feedback from first iPhone install | done | — | [008](008-setup.md) |
| 18 | **Inline edit**: double-tap the revealed front/back to fix it in place | User request | in-progress | ios-engineer | [010](010-inline-edit.md) |
| 19 | Cancel / undo an inline edit (hardware Escape, shake to undo) | Split from 010. Study files: after 011 | backlog | — | |
| 20 | **Ratings**: Forgot / Got it buttons + confidence-dots drag | User request. Starts when 010 merges; design-lead notes first | ready | ios-engineer (design-lead notes) | [011](011-ratings.md) |
| 21 | Rating-drag extras: flick commit, hysteresis, first-run hint | Split from 011. Study files: after 011 | backlog | — | |
| 22 | Store the continuous confidence (0–1) with each review | API step now (012 merged), before 014a (same files); iOS step after 011 (not alongside 009c) | ready | api-engineer → ios-engineer | [013](013-review-confidence.md) |
| 23 | **Native polish: Deck sheet** (large title, `.searchable`, `ContentUnavailableView`, context menu, haptics) | From 009 (design-lead draft). Start now | ready | ios-engineer | [009a](009a-native-deck.md) |
| 24 | **Native polish: Editor + Settings sheets** (toolbar Save/Close, discard dialog, `Form`), launch background, glass `CircleIconButton` | From 009. Start now; design-lead does #7–#8 in parallel | ready | ios-engineer + design-lead | [009b](009b-native-sheets.md) |
| 25 | **Native polish: Study** (`ContentUnavailableView`, counter tick, loading mark, reveal/rate haptics) | From 009. After 011 | ready (blocked on 011) | ios-engineer | [009c](009c-native-study.md) |
| 26 | Logo / brand (round 9) | Animatable `LaCarteLogo`, app icon follow-up | in-progress | design-lead, design-critic | |
| 27 | **Notes (API + MCP)**: typed notes (`basic`, `person`) + cards as directions, 6 h sibling burying, note-level MCP tools, startup migration, `/cards` kept | User request ("remember people from different angles"). Overview [014](014-notes.md). After 013 step 1 | ready | api-engineer | [014a](014a-notes-api.md) |
| 28 | Notes: iOS `APIClient` + `mock-notes` fixtures | No UI. After 007 merges (same files) | ready (blocked on 007) | ios-engineer | [014b](014b-notes-client.md) |
| 29 | Notes: deck lists notes, note editor (type, fields, photo URL, direction toggles) | After 014b, 009a, 009b; design-lead notes first | ready (blocked) | design-lead → ios-engineer | [014c](014c-notes-deck-editor.md) |
| 30 | Notes: Study shows the card's direction (photo, answer hint, context) | Study lane after 011 + 014b; design-lead notes first | ready (blocked) | design-lead → ios-engineer | [014d](014d-notes-study.md) |
| 31 | **Report a card (API + MCP)**: `report` table, held cards leave the queue, `POST /cards/{id}/report`, MCP `list_reports` / `update_report` + instructions | User request (agent-written cards need fixing). After 014a; `api/**` lane | ready | api-engineer | [015](015-report-card.md) (015a) |
| 32 | **Report a card (iOS)**: double-tap the revealed card → report dialog, "Other…" comment, card leaves the session | Study lane after 010 + 011; `APIClient` edit (coordinate with 014b) | ready (blocked on 010, 011) | ios-engineer | [015](015-report-card.md) (015b) |
| 33 | Reports screen in the app (+ REST list/close) | Split from 015. Only if the user wants to follow agent fixes in the app | backlog | — | |
| 34 | MCP prompt `review_reports` (walk through open reports with the user) | Split from 015. Agent ergonomics | backlog | architect → api-engineer | |
