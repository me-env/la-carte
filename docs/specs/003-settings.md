# 003 — Server settings

Status: done
Owners: ios-engineer
Depends on: 002 (DeckFeature hosts the settings button)
Design reference: docs/design/reference/04-list-dark.jpg (gear in the title row), 03-detail-light.jpg (sheet)

## Goal
On a real iPhone the user points the app at their API: they enter the URL and token once, check that the
connection works, and every request from then on uses those values. Covers backlog item 5.

## User stories
- As the user, I open Settings from my deck, enter my API URL and token, and tap "Test connection".
- As the user, I see whether it worked ("Connected · 42 cards"), the token is wrong, or the server is unreachable.
- As the user, after a successful test, my deck and study screen reload from the new server.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | The deck title row shows `deck.settings` (`gearshape`) next to `deck.add`; tapping it presents the settings sheet with `settings.title` "Settings", `settings.url`, `settings.token` (secure), `settings.test` "Test connection", `settings.close` | unit + UI (light + dark) |
| 2 | `settings.url` shows the stored URL (empty on first launch, placeholder "http://127.0.0.1:8000"); edits are stored immediately in `@Shared(.appStorage("apiURL"))` | unit |
| 3 | `settings.token` shows the token stored in the Keychain (masked); edits are saved to the Keychain; an empty field deletes the Keychain item | unit (`TokenStore` mocked) |
| 4 | Tapping `settings.test` shows `settings.status` "Checking…", calls `GET /stats` through the live `APIClient`, then shows "Connected · N cards" (N = `total`), "Wrong token" (HTTP 401) or "Can't reach server" (any other error) | unit + UI |
| 5 | Editing the URL or token after a check clears `settings.status` | unit |
| 6 | The live `APIClient` reads URL and token **at call time** with this precedence: launch env `LA_CARTE_API_URL` / `LA_CARTE_API_TOKEN` > stored value (URL from `UserDefaults` key `apiURL` if it parses as an http(s) URL; token from the Keychain) > default `http://127.0.0.1:8000` / no token. `LA_CARTE_API=mock` still returns the in-memory client | unit (APIClientTests, injected readers) |
| 7 | A successful test sends `delegate(.serverChanged)`; Deck reloads its list and sends `delegate(.deckChanged)`, so study reloads too (spec 002 #11) | unit |
| 8 | `settings.close` (or swiping down) dismisses settings back to the deck | UI |
| 9 | With **no** launch env (neither `LA_CARTE_API` nor `LA_CARTE_API_URL`), entering the e2e URL and token then testing shows "Connected · 2 cards"; replacing the token with "wrong" shows "Wrong token"; URL `http://127.0.0.1:9` shows "Can't reach server" | UI (`_liveAPI`) |

## Screens & states
Sheet over the deck (ref 03 feel): `settings.title` (`.screenTitle`) top-left, `settings.close` (`xmark`)
top-right. Section caption "Server" (`.meta`, `secondaryInk`). Two `surface` rows (radius 12): URL text field
(`.URL` keyboard, no autocapitalization/autocorrection) and token `SecureField` (placeholder
"Token (optional)"). Below: `settings.test` as a quiet text button (`.body`, `ink`), then `settings.status`
(`.meta`, `secondaryInk`). Spec 004 adds an "Appearance" section below.

States: idle (no status), checking, connected, unauthorized, unreachable.
Screenshots: `settings` (light + dark), `settings-connected` (light, mock: "Connected · 3 cards"),
`settings-live-connected`, `settings-live-wrong-token`, `settings-live-unreachable` (light, e2e).

## TCA shape (iOS)
- Module: `SettingsFeature` (new target + tests), child of `DeckFeature` via `Destination.settings(SettingsFeature)`.
- State:
  ```swift
  @Shared(.appStorage(APIClient.urlDefaultsKey)) var apiURL = ""
  var token = ""
  var connection: Connection = .idle
  enum Connection: Equatable { case idle, checking, connected(total: Int), unauthorized, unreachable }
  ```
- Actions (`BindableAction`): `binding`, `onAppear` (loads token from `TokenStore`), `testButtonTapped`,
  `closeButtonTapped`, `statsResponse(Result<DeckStats, any Error>)`, `delegate(Delegate)`.
  `binding(\.token)` → effect `tokenStore.save(token)`; any `binding` resets `connection` to `.idle`.
  *As built:* the URL field sends `urlChanged(String)` instead of a binding, because `BindingReducer` writes
  `@Shared` through its deprecated setter; the reducer writes with `withLock`. URL and token edits also cancel a
  check in flight.
  Each token edit is saved at once in a main-actor effect, so writes stay in order.
- Delegate: `case serverChanged`.
- Dependencies: `\.apiClient` (`stats`), `\.tokenStore`, `\.dismiss`.
- `DeckFeature`: adds `settingsButtonTapped`, `Destination.settings`, and handles `.settings(.delegate(.serverChanged))`.

**`APIClient` module changes** (no TCA, still `Dependencies` only):
- `public static let urlDefaultsKey = "apiURL"` — the single place the key is spelled.
- New `@DependencyClient public struct TokenStore: Sendable { load: () -> String?; save: (String?) throws -> Void }`
  with a Keychain `liveValue` (generic password, service `la-carte`, account `api-token`), unimplemented
  `testValue`, in-memory `previewValue`.
- `HTTP` takes `baseURL: @Sendable () -> URL` and `token: @Sendable () -> String?` closures, evaluated per
  request; `liveValue` builds them from env → `UserDefaults.standard` → `TokenStore` → defaults (criterion 6).
  Keep the resolution in one small, unit-tested function.

## API / MCP changes
None. "Test connection" uses `GET /stats` because `/health` is unauthenticated and can't detect a wrong token.

## Accessibility identifiers
`deck.settings`, `settings.title`, `settings.url`, `settings.token`, `settings.test`, `settings.status`,
`settings.close`.

## Notes for QA
Launch env overrides win over stored values, so criterion 9 needs a launch with no API env at all (add an
`APIMode` case for it in `Support.swift`). Each test types its own values, so values left over from a previous
run don't matter.

## Out of scope
- Showing which values are overridden by the launch environment.
- QR-code / deep-link setup, multiple servers, deploying the API (backlog 6).
