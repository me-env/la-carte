# 030d — Access tokens in Settings (iOS)

Status: ready (after 030c)
Owners: ios-engineer → code-reviewer → qa-validator
Depends on: 030b (`POST /me/tokens`), 030a (`GET`/`DELETE /me/tokens`), 030c (signed-in session, Settings Account
section). Overview: [030](030-accounts-google-login.md) principle 6.
Design reference: docs/design/reference/04-list-dark.jpg (plain list rows), 03-detail-light.jpg (sheet with a form).


> **Amended by [032](032-encryption.md):** no UI change. A `deck` PAT carries the user's key (032b decision 7), so it
> must be created from an unlocked app session (always the case after sign-in); the widget's `stats` token carries none.
## Goal
A signed-in user creates a personal access token (PAT) for a script, CI, or an MCP client that has no OAuth, copies
it once, and can revoke it later. This is the only place PATs are minted: they are API tokens tied to an Apple or
Google sign-in, not passwords.

## User stories
- As the user, I create a token named "laptop script" that expires in 30 days, copy it, and paste it into my
  script.
- As the user, I see my tokens (name, created, last used, expiry) and revoke one I no longer use.

## Decisions
1. Settings → Account → "Access tokens" row (`settings.tokens`) pushes `AccessTokensFeature` (child of
   `SettingsFeature`): a list from `GET /me/tokens`, excluding the app's own `Widget` token (`scope = stats`);
   swipe or context menu "Revoke" → `DELETE /me/tokens/{id}`; toolbar "+" (`tokens.add`).
2. "+" opens a form: name (required, 1–60), expiry picker `Never` | `30 days` | `90 days` | `1 year` (default 90
   days), Create (`tokens.create`). Scope is always `deck` (the widget's `stats` token is not user-made).
3. After creation, one screen shows the token in monospaced text with "Copy" (`tokens.copy`, copies to the
   pasteboard, shows "Copied") and the line "You won't see this token again." Done (`tokens.done`) returns to the
   list. The token is never stored on the device or logged.
4. Errors: 403 ("Create access tokens from the la-carte app") can't happen from the app; 422 (20 tokens) shows
   "You have 20 tokens. Revoke one first."; others "Couldn't create the token. Try again."
5. Mock: three tokens (one never used, one expiring); create returns `lc_pat_mock…`.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `settings.tokens` opens the list showing each token's name, "Created …", "Last used …" / "Never used", "Expires …" / no expiry; the `Widget` token is not listed | both |
| 2 | `tokens.add` → name + expiry → `tokens.create` sends `POST /me/tokens {name, scope: "deck", expires_in_days}` (`null` for Never) and shows the token once with `tokens.copy` | both |
| 3 | `tokens.copy` puts the exact token on the pasteboard and shows "Copied" | unit |
| 4 | `tokens.done` returns to the list, which now contains the new token without its value; reopening never shows the value | both |
| 5 | Revoke on a row sends `DELETE /me/tokens/{id}` and removes the row; a failure restores it with "Couldn't revoke the token. Try again." | both |
| 6 | Create is disabled with an empty name; a 422 shows "You have 20 tokens. Revoke one first." | unit |
| 7 | `DecodingTests`: `PersonalToken` list and create replies | unit |
| 8 | Screenshots, light + dark: `tokens-list`, `tokens-created` | UI |

## TCA shape (iOS)
- Module `AccessTokensFeature` (child of `SettingsFeature` via `@Presents`/navigation destination).
- State: `tokens: IdentifiedArrayOf<PersonalToken>`, `isLoading`, `@Presents destination: .create(CreateState)`,
  `created: String?` (the one-time value), `@Presents alert`.
- Actions: `onAppear`, `tokensResponse`, `revokeSwiped(id)`, `revokeResponse`, `addButtonTapped`, `create(name,
  expiry)`, `createResponse`, `copyButtonTapped`, `doneButtonTapped`.
- Dependencies: `apiClient` (`listTokens`, `createToken`, `revokeToken`), `pasteboard` (existing `AskAIClient` copy
  if reusable, else `UIPasteboard` in a tiny dependency).

## API / MCP changes
None (030a/030b). `APIClient` gains `listTokens`, `createToken`, `revokeToken`.

## Accessibility identifiers
`settings.tokens`, `tokens.add`, `tokens.row.<id>`, `tokens.create`, `tokens.name`, `tokens.expiry`, `tokens.value`,
`tokens.copy`, `tokens.done`.

## Out of scope
- Token scopes other than `deck` in the UI. Editing a token. Showing a token again.
