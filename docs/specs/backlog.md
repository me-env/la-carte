# Backlog

Ordered. The manager moves items into specs (`architect`) one at a time.

| # | Item | Notes | Spec |
|---|---|---|---|
| 0 | Walking skeleton: app ↔ API ↔ MCP, test & screenshot pipeline | Done during setup | 000 |
| 1 | **Study session**: due cards one by one, front → tap to reveal back → rate again/hard/good/easy | Core loop. Home *is* the study screen (Vyst editor layout) | 001 |
| 2 | **Empty / caught-up state**: "All caught up", next due time | Part of study screen | 001 |
| 3 | **Deck list**: all cards, search, swipe to delete | Vyst notes list (04) | 002 |
| 4 | **Add / edit card**: sheet with front + back | Vyst detail (03) | 002 |
| 5 | **Server settings**: API URL + token on device (Keychain), connection check | Needed for real-device use | 003 |
| 6 | **Deploy API**: hosting, HTTPS, token | So agents and phone share the deck | |
| 7 | Themes (light / dark / forest) | `@Shared(.appStorage)` | 004 |
| 8 | MCP prompts: "quiz me", "make cards from this text" | Agent ergonomics | 005 |
| 9 | Offline review queue | Only if needed | |
| 10 | Undo last rating (`arrow.uturn.backward` on study) | Split from 001 | |
| 11 | **Refresh**: pull-to-refresh on study + deck, reload on return to foreground | Split from 001; widened for cards added via MCP while the app is open | [006](006-refresh.md) |
| 12 | Deck pagination beyond 500 cards | Split from 002 | |
| 13 | **Widget**: Home Screen systemSmall, due-now count + study streak (API computes streak with client `tz`) | User request; App Group `group.fr.lacarte.app`, 2nd bundle ID for Ad Hoc | [007](007-widget.md) |
| 14 | Lock Screen widgets (accessoryCircular due count, accessoryRectangular due + streak) | Split from 007 | |
| 15 | Show the streak in the app (caught-up screen) | Split from 007 | |
| 16 | Keep review history when a card is deleted (`ReviewLog.card_id` SET NULL; SQLite table rebuild) | Split from 007: deletions can lower a past streak | |
