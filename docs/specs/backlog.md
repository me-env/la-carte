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
| 11 | Refresh study when the app returns to the foreground | Split from 001 | |
| 12 | Deck pagination beyond 500 cards | Split from 002 | |
