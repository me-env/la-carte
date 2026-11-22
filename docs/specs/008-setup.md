# 008 — Setup: "Connect your deck" and "Token rejected"

Status: done
Owners: ios-engineer
Depends on: 001 (Study), 002 (Deck), 003 (Settings), 006 (refresh; must be merged first, it edits the same files)
Lands before 007 (see "Coordination with 007")
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg (one centered message, quiet
meta line), 05-theme-forest.jpg (forest). No new component.

## Goal
On a fresh install the app no longer tries a server it can't reach. When the server URL or the token is missing it says "Connect
your deck" and opens Settings in one tap. A token the server refuses shows "Token rejected" with the same
button, not the generic offline message. Comes from the user's first install on the iPhone.

## Decisions
- **Release builds never use localhost (user-confirmed).** The built-in `http://127.0.0.1:8000` fallback is
  removed from **every** build. The only ways to reach localhost are launch env `LA_CARTE_API_URL` (UI tests,
  `scripts/e2e.sh`, or an Xcode scheme on the simulator) or typing it in Settings. No `#if DEBUG` branch:
  one rule everywhere, and the "not set up" state can be tested in the simulator.
- **"Set up" means a server URL and a token both resolve** (the user's ask: "when no token is set it should
  propose to set one"). URL: launch env `LA_CARTE_API_URL` > stored http(s) URL. Token: launch env
  `LA_CARTE_API_TOKEN` > Keychain (empty counts as unset). `LA_CARTE_API=mock` is always set up. If either is
  missing, the app shows "Connect your deck" and makes no request.
- **Local dev without a server token** is a dev-only case. The app needs *some* token, and a server started
  without `LA_CARTE_API_TOKEN` ignores the `Authorization` header. So dev runs enter any token (or set
  `LA_CARTE_API_TOKEN` in the scheme / for `scripts/api-dev.sh`). UI tests and e2e pass one through launch env
  (see #14).
- "Token rejected" therefore only shows when a token **was** sent and the server answered 401/403.
- **The decision lives in the reducer**: Study and Deck ask `apiClient.isConfigured()` before every load. No
  request is made when it returns false.
- Settings keeps saving on edit. Closing Settings counts as "saved": Study re-checks and loads. A successful
  "Test connection" is not required.

## User stories
- As a new user, I open the app and see "Connect your deck" with an "Open Settings" button, not an error.
- As the user, I enter my server URL and token, close Settings, and my cards appear.
- As the user, if I haven't entered a token, the app asks me to connect before trying anything.
- As the user, if my token is wrong, the app says "Token rejected" and takes me to Settings.
- As the user, if my server is down, I still see "Can't reach your deck" with retry, as before.

## Acceptance criteria
"Stub" = `StubAPIServer` with the existing token-guarded handler (`SettingsUITests.guarded`), launched with
`APIMode.stored` (no API env).

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | **No localhost default, in any build configuration.** `APIClient.resolvedBaseURL(environment:stored:)` returns `URL?`: launch env `LA_CARTE_API_URL` > stored http(s) URL > **`nil`**. `nil`, `""`, `"   "`, `"ftp://x"` and `"localhost"` (no scheme) all give `nil`. No code path builds `http://127.0.0.1:8000` | unit (APIClientTests) + review (grep finds no `127.0.0.1` in `Sources/`) |
| 2 | `APIClient` gains `isConfigured: @Sendable () -> Bool`. Live: `resolvedBaseURL(...) != nil && resolvedToken(...) != nil`, read **at call time** from the same readers as `baseURL` and `token`. Cases: URL + token → true; URL only → false; token only → false; neither → false; env URL + env token → true; empty stored token → false. In-memory (`LA_CARTE_API=mock`, previews): `true` | unit |
| 3 | If a live request runs with no URL (e.g. Settings "Test connection" with an empty field), it throws without any network call, and Settings shows "Can't reach server" | unit |
| 4 | **Study, not set up** (no URL, no token, or neither): when `isConfigured()` is false, `onAppear`, `retryButtonTapped`, `deckChanged`, `pulledToRefresh` and `scenePhaseChanged(.active)` set the phase to `.notSetUp` and clear the cards, with **no** call to `dueCards`, `stats` or `review`. The screen shows `study.message` "Connect your deck", `study.detail` "Add your server URL and token in Settings." and `study.openSettings` "Open Settings". `study.remaining` and `study.retry` are absent | unit + UI (light, dark, forest) |
| 5 | Tapping `study.openSettings` presents the Settings sheet (`settings.title`) **directly over Study** (not via the deck), with the stored URL and masked token, as in 003 | unit + UI |
| 6 | Closing Settings opened from Study (`settings.close` **or** a swipe down) re-runs Study's load: URL or token still missing → stays "Connect your deck"; both set → due cards load (`study.front` shows). UI (stub): Connect your deck → Open Settings → type stub URL only → close → still "Connect your deck" → Open Settings → type good token → close → `study.front` shows the stub's first card | unit + UI |
| 7 | A successful "Test connection" in Settings opened from Study reloads Study while the sheet stays open (same `serverChanged` delegate as 003 #7) | unit |
| 8 | **Token rejected**: a `dueCards`, `stats` or `review` failure with `APIError.statusCode` 401 or 403 sets the phase to `.unauthorized` (and clears `isReviewing`). The screen shows `study.message` "Token rejected", `study.detail` "Check your token in Settings." and `study.openSettings`; no `study.retry`. UI (stub): type stub URL + token "wrong" → close → "Token rejected" | unit + UI (light, dark, forest) |
| 9 | Any other failure (no connection, 5xx, decoding) still shows the existing offline state ("Can't reach your deck" + `study.retry`), unchanged | unit (existing tests) |
| 10 | In "Connect your deck" and "Token rejected", returning to the foreground (pull to refresh removed in 018) re-run the check/load (rule from 006), and `study.deck` / `study.add` stay in the top bar | unit |
| 11 | **Deck**: the same rules apply to `loadCards`. Not set up (no URL or no token) → `deck.message` "Connect your deck"; 401/403 → `deck.message` "Token rejected". Both show `deck.openSettings` "Open Settings" under the message, which opens the deck's Settings sheet (same as `deck.settings`). Offline → "Can't reach your deck" as before, with no button | unit + UI (light, dark) |
| 12 | Closing Settings opened from the deck (close or swipe) reloads the deck with the current query and sends `delegate(.deckChanged)`, so Study re-checks too. UI (stub): from Study open deck → `deck.settings` → clear `settings.token` → close → `deck.message` "Connect your deck" → close deck → `study.message` "Connect your deck" | unit + UI |
| 13 | Settings copy: `settings.url` placeholder "Server URL" (no localhost hint), `settings.token` placeholder "Token". "Test connection" shows "Wrong token" for 401 **and** 403 | unit + UI (existing settings screenshot) |
| 14 | Existing suites keep passing: mock UI suite (`LA_CARTE_API=mock` is configured), `scripts/e2e.sh` (sets `LA_CARTE_API_URL` + `LA_CARTE_API_TOKEN`), and the `.stored` settings tests (they type URL + token before expecting data). **`Support.swift` (qa-validator):** `APIMode.live(url)` sets `LA_CARTE_API_TOKEN` to the runner's token or, when that is unset, to `"ui-test-token"`, so the stub-based Refresh/Deck tests stay set up (unguarded stub handlers ignore the header). Existing Study/Deck TestStore tests set `$0.apiClient.isConfigured = { true }` | unit + UI |
| 15 | On the iPhone, after deleting the app and installing the Ad Hoc build: "Connect your deck" → Open Settings → production URL + token → close → cards (or "All caught up"). No "Can't reach your deck" at any point | **user** device check (manual), recorded by QA as pending/confirmed |
| 16 | **Token field is masked, not a `SecureField`.** `settings.token` shows one dot per character by default, has `.privacySensitive()` and the VoiceOver label "Token". The eye button `settings.token.reveal` (`eye` / `eye.slash`) toggles plain text. Tapping the token row reveals the token and focuses the field; it masks again when focus leaves. Editing still saves to the Keychain as in 003 #3. Typing a token and closing Settings shows **no** "Save Password?" prompt, and the next screen takes taps at once. *Why:* iOS offers "Save Password?" for any secure text entry, and that prompt blocked taps after Settings closed; `.textContentType(.oneTimeCode)` did not prevent it | unit (reveal/focus state) + UI (masked, revealed, close → `study.front` or `study.message` tappable) |

## Screens & states
Study content area, centered, inside the existing `pullable` scroll view (same layout as offline):
```
          Connect your deck                 study.message   .body, ink
 Add your server URL and token in Settings. study.detail    .meta, secondaryInk
            Open Settings                   study.openSettings  text button, .body, ink, min 44 pt, .plain
```
"Token rejected" uses the same layout with its own copy. Spacing `Theme.Spacing.s` between message and detail,
`Theme.Spacing.m` above the button. It is a quiet text button like "Show answer" and "Test connection": no
circle, fill or tint. Top bar unchanged (deck + add; `study.remaining` hidden).

Deck: `deck.message` as today, with `deck.openSettings` (same text button) below it, only in those two states.
Settings: unchanged except the placeholders (#13) and the masked token field (#16).

Screenshots (`<screen>-<state>`, light + dark, plus forest where noted, with `-theme forest`):
`study-not-set-up` (+ forest), `study-token-rejected` (+ forest), `settings-from-study` (light),
`study-after-setup` (light, card shown after #6), `deck-not-set-up`, `deck-token-rejected` (light),
`settings-token-masked`, `settings-token-revealed` (light, #16).
User device photo for #15 if provided.

> **Design note (design-lead, 2026-11-21, native-audit.md):** these states are what `ContentUnavailableView`
> is for: `ContentUnavailableView { Label("Connect your deck", systemImage: "link") } description: { Text(…) }
> actions: { Button("Open Settings") { … } }`, still inside `pullable`, with the same ids on the inner texts
> and the button. Use it **only if the views aren't built yet**. Otherwise ship 008 as written: spec 009 moves
> every message state (offline, not set up, token rejected, deck messages) to it in one go.

## TCA shape (iOS)
No new module.

**`APIClient`**: `isConfigured` endpoint (#2). `resolvedBaseURL` returns `URL?` (#1). `HTTP.baseURL` becomes
`@Sendable () -> URL?`; `nil` throws `URLError(.unsupportedURL)` before any request (#3). `APIError` gains
`var isUnauthorized: Bool { statusCode == 401 || statusCode == 403 }`, the single place this is spelled. Study,
Deck and Settings all use it.

**`StudyFeature`**
- State: `Phase` gains `.notSetUp` and `.unauthorized`.
- Actions: `openSettingsTapped`; `Delegate` gains `settingsRequested`.
- Every load trigger goes through one helper (today's `fetchDueCards()`), which checks `apiClient.isConfigured()`
  first. If that is false it sets `.notSetUp`, `cards = []`, `isRevealed = false`, and returns
  `.cancel(id: CancelID.load)`. The `isReviewing` guard from 006 stays in front of it for refresh/foreground.
- Failures: `(error as? APIError)?.isUnauthorized == true` → `.unauthorized`, otherwise `.offline`.
- View: two new `case`s in `content`, sharing one small private builder with the offline layout if that reads
  clearer.

**`AppFeature`**
- `Destination` gains `case settings(SettingsFeature)`; `AppView` adds the `.sheet` for it.
- `.study(.delegate(.settingsRequested))` → `state.destination = .settings(SettingsFeature.State())`.
- `.destination(.presented(.settings(.delegate(.serverChanged))))` → `.send(.study(.deckChanged))`.
- `.destination(.dismiss)` while `destination` is `.settings` → `.send(.study(.deckChanged))`. Handle it in the
  parent `Reduce`, which runs before `.ifLet` clears the state. `\.dismiss` from `settings.close` and the swipe
  both arrive as `.destination(.dismiss)`.

**`DeckFeature`**
- `Phase` gains `.notSetUp`, `.unauthorized`; `message` maps them to the copy above; a computed
  `showsSettingsButton` (true in those two phases).
- `loadCards` checks `isConfigured()` the same way (sets `.notSetUp`, `cards = []`, no request).
- `openSettingsTapped` → same as `settingsButtonTapped` (or the view sends `settingsButtonTapped`; the engineer
  picks one, without adding a duplicate action).
- `.destination(.dismiss)` while `destination` is `.settings` → reload with the query + `delegate(.deckChanged)`
  (#12), the same as the existing `serverChanged` branch.

**`SettingsFeature`**: placeholders (#13); `statsResponse(.failure)` uses `isUnauthorized`. Token field (#16):
`isTokenRevealed: Bool` in State, a `tokenRevealButtonTapped` action, and the view's `@FocusState` on the token
field (row tap sets reveal + focus; focus loss sets `isTokenRevealed = false`). The masked text is a plain
`TextField` whose displayed value is dots while hidden; no `SecureField` anywhere.

**Tests**: APIClientTests (#1–#3, incl. the `isConfigured` truth table in #2), StudyFeatureTests (#4, #5 delegate, #8, #9, #10: one test per trigger is
not needed, one for `onAppear` + one for `pulledToRefresh` is enough), AppFeatureTests (#5 presentation, #6
dismissal → `study(.deckChanged)`, #7), DeckFeatureTests (#11, #12).

## Coordination with 007 (widget)
008 lands **first**. It is the user-visible fix, it is smaller, and it does not touch storage. It only changes
what happens when the stored URL is missing, not where the URL is stored. `isConfigured` and `baseURL` share
one `stored` reader in `liveValue`. When 007 moves `apiURL` to the App Group suite, it changes that one reader
and both follow. 007 #14 ("existing suites pass unchanged") then includes 008's tests. The widget's own
unconfigured case is already covered by 007 #20 ("Can't reach your deck" / cached stats). Better widget copy
for it is out of scope here.

## API / MCP changes
None. The API already returns 401 without a valid bearer token.

## Docs to update in the implementing change
- `docs/architecture.md`: the `LA_CARTE_API_URL` row and the precedence line become "launch env > stored value
  > none (app shows Connect your deck)". Remove "default `http://127.0.0.1:8000`".
- `docs/deploy.md` (~line 85): the app no longer has a built-in default.
- `docs/testing.md`: to run the app from Xcode on the simulator against `scripts/api-dev.sh`, set
  `LA_CARTE_API_URL=http://127.0.0.1:8000` and any `LA_CARTE_API_TOKEN` in the scheme, or type both once in
  Settings. A server without a token ignores the header. `APIMode.live` always sends a token (#14).
- `docs/design-system.md`: one line under Screen patterns: setup/error message = `.body` ink message, `.meta`
  detail, quiet text button.
- Spec 003 #6 and #2 (placeholder) are superseded by this spec; add a one-line note in 003.

## Accessibility identifiers
- `study.message` (existing, new copies), `study.detail` (new, meta line), `study.openSettings` (new)
- `deck.message` (existing, new copies), `deck.openSettings` (new)
- `settings.token` (existing, now masked text field), `settings.token.reveal` (new, eye toggle, #16)

## Notes for QA
- Leftover stored values don't matter. Each `.stored` test clears or types `settings.url` / `settings.token` itself (reach
  Settings through `study.openSettings` if visible, otherwise `study.deck` → `deck.settings`).
- Forest screenshots: launch with `-theme forest` and don't touch the theme picker.
- Do not test "not set up" with a `-apiURL ""` launch argument. The argument domain would override what
  Settings writes, so #6 could not pass.

## Out of scope
- Onboarding/welcome screens, QR-code or deep-link setup, pre-filling the production URL.
- Hiding `study.add` / `study.deck` while not set up (the editor's existing error handling covers add).
- Widget copy for an unconfigured app (007 shows "Can't reach your deck").
- Validating the URL format in Settings beyond today's "http(s) with a host" rule.
