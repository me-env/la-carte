# 010 — Inline edit on the revealed card

Status: ready
Owners: ios-engineer (design-lead fills "Design notes" first)
Depends on: 001 (study), 006 (refresh rule). Independent of 009 (draft); if 009 lands first, nothing here changes.
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg (the card face; Vyst edits text
in place, with no visible field chrome).

## Goal
While studying, the user fixes a typo or a weak answer without leaving the card: on the revealed card, a
double-tap on the front or the back turns that text into an editable field, in place, and the change is saved to
the deck when they're done.

## User stories
- As the user, I reveal a card, notice the answer is wrong, double-tap it, fix it, tap Done, and keep studying.
- As the user with VoiceOver, I use the "Edit" action on the front or back to do the same.

## Interaction rules (decided)
- **Only on the revealed card.** Before reveal there is no double-tap gesture at all, so the single tap that
  reveals (001 #2) is not delayed. After reveal a single tap on the card does nothing (as today), so the
  double-tap gestures on `study.front` / `study.back` cost nothing. The view attaches
  `.onTapGesture(count: 2)` to each text only while `isRevealed && editing == nil`.
- **One field at a time.** Double-tap front edits the front; double-tap back edits the back.
- **Commit** = keyboard Done/return, or the field losing focus: tapping the card area outside the field, swiping
  the keyboard down (`.scrollDismissesKeyboard(.immediately)` plus a swipe-down gesture while editing; any focus loss sends one `editEnded` — amended 2026-11-21), or tapping
  `study.deck` / `study.add` (the edit is committed, then the sheet opens).
- **No cancel gesture** (iOS has no Escape without a hardware keyboard). Leaving the text unchanged commits
  nothing. A text that is empty after trimming is not allowed: the edit ends and the old text comes back, with
  no request.
- **Return ends the edit**: cards are short, so return never inserts a newline (`.submitLabel(.done)`). Existing
  newlines in a card's text are kept. If `onSubmit` does not fire for a vertical `TextField` on iOS 27, the
  reducer treats a newline typed at the end of the draft as submit and drops it.
- **Saved text is trimmed** (leading/trailing whitespace), like the editor (002 #8).
- **While editing**: the rating row and `study.reveal` are not shown, pull-to-refresh and foreground reloads are
  skipped (006 rule, extended), and starting the edit cancels any due-cards load in flight, so no response can
  replace the card under the user's fingers. A second edit can't start while a save is in flight.
- **Save is optimistic**: the new text shows immediately, `PATCH /cards/{id}` runs, and the server's card
  replaces it on success. On failure the old text comes back, an error haptic plays, and `study.editError`
  "Couldn't save the edit" replaces the counter until the user rates or starts another edit. Any failure
  (offline, 401) is handled this quietly; the screen does not go to the offline/unauthorized state.
- Rating is allowed while a save is in flight (both requests are independent). A save response for a card no
  longer in the queue is ignored.

## Acceptance criteria
Mock deck = `LA_CARTE_API=mock` (fixtures `serendipity` / "finding something good without looking for it", ...).
"Stub" = `StubAPIServer` in the UI-test runner (to make `PATCH` fail).

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | On an unrevealed card, double-tapping `study.front` reveals the card (the first tap reveals, as 001 #2) and does **not** open an editor: `study.frontField` does not exist | unit + UI |
| 2 | On the revealed card, double-tapping `study.front` replaces it with `study.frontField` containing "serendipity", focused, keyboard shown; `study.back` stays visible; the rating buttons `study.rate.*` do not exist | unit + UI (light, dark, forest) |
| 3 | On the revealed card, double-tapping `study.back` replaces it with `study.backField` containing the back, focused; `study.front` stays visible; no rating buttons | unit + UI |
| 4 | Changing the back to "a happy accident" and tapping the keyboard's Done (return) shows `study.back` "a happy accident" immediately, sends `PATCH /cards/{id}` with that front and back, and the rating buttons come back; the card stays revealed and is still the current card | unit + UI |
| 5 | Tapping the card area outside the field, or swiping the keyboard down, commits the same way as #4 | UI |
| 6 | Tapping `study.add` while editing commits the edit (PATCH sent) and opens the "New card" editor | unit + UI |
| 7 | Committing with an unchanged text, or with text that is empty after trimming, sends no request and shows the previous text | unit |
| 8 | Committed text is trimmed: "  a happy accident \n" is saved and shown as "a happy accident" | unit |
| 9 | If the PATCH fails, the previous text comes back, `study.editError` reads "Couldn't save the edit" in place of `study.remaining`, and the screen stays on the card (not offline). Rating the card or starting another edit clears the message | unit + UI (stub PATCH 500) |
| 10 | While editing, `pulledToRefresh` and `scenePhaseChanged(.active)` call no API and change no state; entering edit cancels a due-cards load in flight (its response never arrives) | unit |
| 11 | While a save is in flight, a double-tap does not start another edit, and `pulledToRefresh` / `scenePhaseChanged(.active)` are skipped; a successful save cancels nothing else and leaves `isRevealed` true | unit |
| 12 | A save response for a card that was rated meanwhile (no longer in `cards`) changes nothing | unit |
| 13 | VoiceOver: on the revealed card, `study.front` and `study.back` each expose an accessibility action named "Edit" that starts the edit (same as the double-tap). Before reveal there is no "Edit" action | UI (`accessibilityCustomActions` / perform action) |
| 14 | The field looks like the text it replaces: same font (`.cardFace` front, `.body` back), same color, centered, no border or background; only the cursor (and selection) show it's editable. A light selection haptic plays when the edit starts | screenshot review + review |
| 15 | Long text (a back of ~200 characters) wraps inside the field and the card scrolls; at Dynamic Type accessibility XL the field stays readable and is not clipped by the keyboard (the card's scroll view keeps it reachable) | UI (light) |
| 16 | Live API (`scripts/e2e.sh`): reveal `bonjour`, double-tap the back, append "!", Done → `GET /cards` from the runner shows the new back; the test then restores the original back with `PATCH` (deck-neutral; runs before `testStudy_revealRateToCaughtUp_liveAPI`) | UI (`_liveAPI`) |

## Screens & states
One new state of the studying screen: **editing** (front or back). Layout unchanged otherwise: the field takes the
text's place in the card's `ScrollView`; the bottom slot (rating row / reveal) is empty while editing; the system
keyboard avoidance shrinks the card area. The counter slot shows `study.editError` (`.meta`, `secondaryInk`, no
red, no pink) after a failed save.

Screenshots (light + dark + forest unless noted): `study-editing-front`, `study-editing-back` (light + dark),
`study-edited` (light, after #4), `study-editing-long` (light, #15), `study-editing-xl` (light, AX XL, #15),
`study-edit-error` (light, #9), `study-edit-live` (light, e2e #16).

## TCA shape (iOS)
No new module. `StudyFeature` only; `APIClient` unchanged (`updateCard(id, front, back)` exists, with the
in-memory implementation).

- State (new):
  ```swift
  var editing: Field?        // which text is being edited; nil = not editing
  var draft = ""             // the field's text
  var isSavingEdit = false   // PATCH in flight
  var editFailed = false     // shows study.editError
  enum Field: Equatable { case front, back }
  ```
- Actions (new): `binding(BindingAction<State>)` (`StudyFeature.Action` becomes `BindableAction`, view binds
  `$store.draft`), `textDoubleTapped(Field)` (also sent by the VoiceOver "Edit" action), `cardTapped`,
  `editEnded` (Done/return and focus loss; idempotent: `guard editing != nil`),
  `editSaveResponse(Result<Card, any Error>, previous: Card)`.
- `cardTapped` replaces the card's `onTapGesture { reveal() }`: editing → same as `editEnded`; not revealed →
  reveal (view keeps the `withAnimation` wrap); revealed → nothing. `study.reveal` keeps `revealTapped`.
- `textDoubleTapped(field)`: `guard isRevealed, editing == nil, !isSavingEdit, phase == .studying`; set `editing`,
  `draft` = that field's text, `editFailed = false`; return `.cancel(id: CancelID.load)`.
- `editEnded`: trim `draft`; set `editing = nil`. Empty or unchanged → `.none`. Else: keep `previous` card,
  write the trimmed text into `cards[id:]` (optimistic), `isSavingEdit = true`, run
  `updateCard(id, front, back)`.
- `editSaveResponse`: `isSavingEdit = false`. Success → replace the card if still in `cards`. Failure → put back
  `previous` if still in `cards`, `editFailed = true`.
- `pulledToRefresh`, `scenePhaseChanged(.active)`: guard becomes `!isReviewing && editing == nil && !isSavingEdit`.
- `ratingTapped`: also sets `editFailed = false`.
- View: `@Bindable var store`; `@FocusState` focused when the field appears; `.onChange(of: focus)` sends
  `editEnded` on focus loss; `.onSubmit { store.send(.editEnded) }`; `TextField(axis: .vertical)` with the text's
  font/color/alignment, `.submitLabel(.done)`, `.tint(Theme.accent)` on the field (design-system accent rule 2,
  pending design-lead, see below); `.sensoryFeedback(.selection, trigger: store.editing) { _, new in new != nil }`
  and `.sensoryFeedback(.error, trigger: store.editFailed) { _, new in new }`;
  `.accessibilityAction(named: "Edit")` on each text while revealed.
- Delegate: none (Deck isn't on screen; it reloads when opened).
- Tests (`StudyFeatureTests`): one per logic criterion: #1, #2/#3 (state), #4 (optimistic + PATCH args),
  #6 (`cardTapped` and `editEnded` paths), #7, #8, #9 (rollback + `editFailed`, cleared by rating / new edit),
  #10 (`dueCards` suspended on a `TestClock`, edit start cancels it; refresh skipped), #11, #12.

## API / MCP changes
None. Uses `PATCH /cards/{id}` with `{"front": "...", "back": "..."}` (scheduling kept; `CardUpdate` rejects
empty strings, which the app never sends). MCP already has `update_card`.

## Accessibility identifiers
New: `study.frontField`, `study.backField` (the editing fields), `study.editError`.
Unchanged: `study.front`, `study.back` (now carry the "Edit" accessibility action when revealed), `study.card`.

## Design notes (design-lead)
Native first: it's a plain `TextField` that looks exactly like the text it replaces. Nothing new to learn.
- **Accent (decided):** the cursor and selection are pink (`.tint(Theme.accent)` on the field only). While editing,
  the counter slot is **empty**, like the rating slot: `study.remaining` (and 009's pink number) is hidden while
  `editing != nil`, so pink stays one element per screen. Rule 2 in `docs/design-system.md` says this now. The
  counter comes back when the edit ends (no animation needed; `Theme.Motion.standard` fade if it's free).
- **Keyboard (decided):** keep system keyboard avoidance. Don't pin the card. The top bar stays where it is, and the
  card's `ScrollView` shrinks and keeps the field visible: on focus, scroll the field into view
  (`ScrollViewReader.scrollTo(field, anchor: .center)` or `.scrollPosition(id:)`). `.scrollDismissesKeyboard(.immediately)`
  as specified. Never cover the field with the keyboard at AX sizes (#15).
- **Affordance:** no border, background, underline or placeholder. The caret is the only sign it's editable. The
  field keeps the text's font, color, centering and Dynamic Type cap (`...accessibility2`). No transition between
  text and field (they're identical); the text must not jump (same padding/line height, so no layout shift).
- **Haptics (`.sensoryFeedback`):** `.selection` when an edit starts; `.error` when a save fails. **None** on a
  successful save: the text staying is the feedback, and saving is quiet and optimistic.
- **Error line:** `study.editError` "Couldn't save the edit" in the counter slot, centered, `.meta`, `secondaryInk`.
  No icon, no red, no pink. It fades in with `Theme.Motion.standard` (no extra motion, so Reduce Motion needs no
  variant). VoiceOver: post `AccessibilityNotification.Announcement("Couldn't save the edit")` when it appears.
- **VoiceOver "Edit" action:** after it starts the edit, focus moves to the field (`@AccessibilityFocusState` or
  the `@FocusState` above). The field's label is "Front" / "Back".

## Notes for QA
- Double-tap: `element.doubleTap()`. The fields are `textViews` or `textFields` depending on the axis; query by id
  with `app.descendants(matching: .any)["study.backField"]`.
- #9 needs the stub to answer `PATCH` with 500 while `GET /cards/due` succeeds.
- #16 must leave the seeded deck unchanged (restore the back), add it to `scripts/e2e.sh`'s `-only-testing` list
  before the caught-up live test.

## Out of scope
- Editing an unrevealed card, or editing from the caught-up screen; editing both sides at once.
- Cancel/undo of an edit (hardware-keyboard Escape, shake to undo); discard confirmation.
- Newlines in inline edits (the full editor in the deck still allows them).
- The narrow race where a `deckChanged` reload (only possible after a sheet, i.e. after the edit committed) is
  answered with the pre-PATCH text; the next refresh corrects it (same class as 006's out-of-scope races).
