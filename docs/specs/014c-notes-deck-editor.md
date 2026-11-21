# 014c — Notes: deck list and note editor

Status: ready (blocked: starts after 014b, 009a and 009b merge; design-lead notes first)
Owners: ios-engineer (design-lead notes first)
Depends on: 014b (client), 014a deployed (live API), 009a (Deck sheet) and 009b (editor sheet) merged.
Shared model: [014](014-notes.md). Backlog #29.
Design reference: docs/design/reference/04-list-dark.jpg (deck rows), 03-detail-light.jpg (editor sheet);
Apple Contacts "New Contact" (photo + fields), Reminders "Details" (toggles).

**Parallelism.** Touches `DeckFeature/**`, `CardEditorFeature/**` (renamed `NoteEditorFeature/**`),
`AppFeature/AppFeature.swift` (destination case), `Package.swift` (target rename), `APIClient` (removing endpoints
no longer used), their tests. Not Study (`StudyFeature/**` only renames its `addCardRequested` handling in
`AppFeature`, no Study file edit). Runs in parallel to 014d (Study lane).

## Goal
The user manages notes, not loose cards: the deck shows one row per note with its directions, and the editor
lets them pick a type, fill its fields (a person's photo URL, name, role, context) and choose which directions
to study.

## User stories
- As the user, I add a person with a photo URL, a name and what they do, and pick "photo → name" and
  "role → name"; both become cards.
- As the user, I open a vocabulary card and turn on "back → front" because I need to produce the word too.
- As the user, I fix a typo in a person's name once and every angle shows the fix.

## Acceptance criteria
Mock = `LA_CARTE_API=mock-notes` (014b).

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | The deck lists **notes** (`apiClient.notes(query)`), one row per note: `deck.row.<noteId>`. 4 rows in the mock | unit + UI |
| 2 | Row text: line 1 = the note's key field (`basic.front`, `person.name`), line 2 = `basic.back`, or `person.role` (else `context`). Meta: left = the earliest `due` among its cards (format unchanged, `deck.row.<id>.due`); right = the single card's state as today when the note has one card, else "N directions" (`deck.row.<id>.state`) | unit (row model) + UI |
| 3 | A `person` row shows the photo as a small thumbnail when present (size/placement per design notes; `deck.row.<id>.photo`, accessibility label "Photo"); a failed load shows the placeholder symbol, never a broken layout | UI |
| 4 | Search filters notes server-side over all text fields (unchanged debounce); "bakery" finds the person | unit + UI |
| 5 | Swipe-to-delete and the context-menu Delete delete the **note** (`deleteNote`); the row disappears; `deckChanged` is sent | unit + UI |
| 6 | Tapping a row (or context-menu Edit) opens the editor for that note | unit + UI |
| 7 | Editor, new note: segmented type picker Basic / Person (`editor.type`), Basic selected. Changing the type swaps the fields and resets the directions to that type's defaults. Editing an existing note shows no picker (type is fixed) | unit + UI |
| 8 | Fields per type, in order, one text field each with id `editor.<field>` (`editor.front`, `editor.back` unchanged; `editor.photo`, `editor.name`, `editor.role`, `editor.context`). `editor.photo` uses the URL keyboard, no autocorrection/capitalization, and shows a live preview (`editor.photoPreview`) once the text is an http(s) URL | UI |
| 9 | Directions section: one toggle per catalog direction (`editor.direction.<prompt>-<answer>`, field names joined by `+`): basic `front-back`, `back-front`; person `photo-name`, `photo-name+role`, `role-name`. Labels use field labels ("Photo → Name + Role"). An existing note's directions outside the catalog are listed too, on | unit + UI |
| 10 | Defaults, **never automatic reverse**: new basic → only `front-back` on; new person → none on | unit + UI |
| 11 | A toggle whose fields are empty is disabled (can't be turned on); one already on stays on | unit + UI |
| 12 | Save (`editor.save`) is enabled only when: required fields present (basic both, person name), ≥ 1 direction on, every direction that is on has its fields filled, and `photo` is empty or an http(s) URL. With no direction on, `editor.directionsHint` reads "Choose at least one direction" | unit + UI |
| 13 | Save on a new note calls `addNote(draft)`; on an existing note `updateNote(id, draft)` with the full fields and direction set (turning a direction off deletes that card server-side; turning one on adds it); then `delegate(.saved(Note))` and dismiss. Failure keeps the sheet with `editor.error` (unchanged) | unit |
| 14 | 009b's discard protection treats any field or direction change as unsaved | unit |
| 15 | Titles: "New card" / "Edit card" for basic, "New person" / "Edit person" for person (`editor.title`) | UI |
| 16 | The Study `+` button opens the same editor for a new note; saving refreshes Study (`study(.deckChanged)`) | unit (`AppFeatureTests`) + UI |
| 17 | Live E2E: create a person note with 2 directions in the app; the API (`GET /notes`) has it with 2 cards; delete it from the deck; `GET /notes/{id}` → 404 | UI (`_liveAPI`) |
| 18 | `APIClient.cards`, `addCard`, `deleteCard` are removed if no feature uses them anymore | review |
| 19 | Dynamic Type up to AX5 doesn't clip the editor or rows; every interactive element has an id | UI (AX5) |

## Screens & states
Screenshots (light + dark; forest for `deck-notes`): `deck-notes` (4 rows, person thumbnail),
`deck-notes-search` ("bakery"), `editor-basic-new` (defaults), `editor-basic-reverse` ("la carte", both on),
`editor-person-new` (empty, no direction on, hint visible), `editor-person-filled` (photo preview, 2 directions on),
`editor-person-ax5` (light).

## TCA shape (iOS)
- Module rename: `CardEditorFeature` → `NoteEditorFeature` (target + tests). `AppFeature.Destination.addCard` →
  `.addNote(NoteEditorFeature)`; `StudyFeature.Delegate.addCardRequested` keeps its name (no Study edit).
- `DeckFeature.State.cards: IdentifiedArrayOf<Card>` → `notes: IdentifiedArrayOf<Note>`; `rowTapped(Note.ID)`,
  `rowSwipedToDelete(Note.ID)`, `notesResponse(Result<[Note], any Error>)`, `deleteResponse(Result<Note.ID, …>)`.
  Destination `.editor(NoteEditorFeature)`.
- `NoteEditorFeature.State`: `let note: Note?`, `var type: NoteType`, `var fields: [String: String]` (all of the
  type's fields), `var directions: [Direction]` (on, in catalog order), `isSaving`, `saveFailed` (+ 009b's
  discard state). Derived: `catalog` (type's catalog + note's extras), `canSave`, `isUnavailable(Direction)`,
  `draft: NoteDraft`.
- Actions: `typeChanged(NoteType)`, `fieldChanged(String, String)`, `directionToggled(Direction)`,
  `saveButtonTapped`, `closeButtonTapped`, `saveResponse(Result<Note, any Error>)`, `delegate(.saved(Note))`
  (+ 009b's discard actions). The direction catalog is a static per-type list in the feature (UI choice, not API).
- Dependencies: `apiClient.notes/addNote/updateNote/deleteNote`, `dismiss`, `continuousClock` (search debounce).
- Delegates: `NoteEditor.saved` → Deck/App (as `CardEditor.saved` today); `Deck.deckChanged` unchanged.

## Design notes (design-lead, before engineering)
Native `Form` from 009b; no accent beyond the focused field's cursor (rule 2, `.tint(Theme.accent)` on each field,
`editor.photo` included). Nothing else is pink: checkmarks, picker, photos stay ink/grey.

**Editor layout** (sections top to bottom, `.scrollContentBackground(.hidden)`, rows `Theme.surface`):
1. *Type* (new note only): `Picker` `.segmented` "Basic" / "Person", no header, `.listRowBackground(Color.clear)`.
   Tint ink, like Settings' theme picker. Switching is instant (no animation besides the system's row change).
2. *Basic*: one section, `Front`, `Back` (placeholders as today).
   *Person*: section 1 = photo; section 2 = `Name`, `Role` (placeholder "What they do"), `Context` (placeholder
   "How you know them", `axis: .vertical`, `lineLimit(1...3)`).
3. *Photo section* (person): row 1 = `editor.photoPreview`, a `CardPhoto(.preview)` circle centered in the row
   (`.listRowBackground(Color.clear)`, like Contacts' new-contact avatar); row 2 = `editor.photo` field,
   placeholder "Photo URL". The preview is **always laid out** (88 pt), so typing never jumps the form:
   empty/invalid URL and loading → placeholder (no spinner); success → image, fades in `Theme.Motion.standard`
   (Reduce Motion: none); failure → placeholder symbol + section footer "Couldn't load this photo" (`.meta`,
   `secondaryInk`). A failed photo never blocks Save (out of scope: validating the URL loads).
4. *Directions*: `Section("Directions")`, one **checkmark row** per catalog direction, not a `Toggle` switch
   (why: a switch's on-track is either system green or an ink track whose white knob vanishes in dark/forest; the
   checkmark row is the native multi-select idiom, monochrome). Row = `Button` with the label left in `ink` and a
   trailing `checkmark` (SF Symbol, ink, regular) when on; `.accessibilityAddTraits(.isSelected)` when on;
   ids unchanged (`editor.direction.<prompt>-<answer>`). Label: field labels joined by " → " for the side and
   " + " inside a side: "Front → Back", "Back → Front", "Photo → Name", "Photo → Name + Role", "Role → Name".
   VoiceOver label reads "Photo to Name and Role". Unavailable rows (#11) use `.disabled` (system dimming), no
   extra text. Footer: with none on, `editor.directionsHint` "Choose at least one direction"; otherwise
   "Each direction is its own card." (both `.meta`, `secondaryInk`).
5. Titles: navigation title (009b removed the `editor.title` text): QA reads them via `app.navigationBars`;
   architect: align #15's id with 009b.

**Deck row** (009a list, radius 12, `surface`): a `person` row always has a leading `CardPhoto(.thumbnail)`
(44 pt circle, `Theme.Spacing.m` to the text, vertically centered; top-aligned at accessibility sizes, never
scaled), placeholder symbol when there's no photo or it fails, so people read as people at a glance. Basic rows have
no thumbnail (unchanged). Meta right: one card → state as today; several → "2 directions" (`.meta`,
`secondaryInk`, no symbol).

**`CardPhoto`** (new, `DesignSystem/CardPhoto.swift`, shared with 014d; whichever lands first builds it, design-lead
reviews + adds the gallery entry): `CardPhoto(url: URL?, style: .thumbnail | .preview | .card)`. `AsyncImage`
phases in a fixed frame: placeholder = `Theme.hairline` fill; failure/nil = `person.fill` in `secondaryInk` at ⅓ of
the frame; success = `.scaledToFill()` clipped. `.thumbnail` (`Theme.Photo.thumbnail` 44) / `.preview` (`Theme.Photo.preview` 88) = circle; `.card` (width
`Theme.Photo.card` 240, `cardCompact` 160 at AX sizes; 014d) = 4:5 portrait,
`RoundedRectangle(cornerRadius: Theme.Radius.photo, style: .continuous)`. Every style has a 1 pt inner
`Theme.hairline` stroke (white photos don't bleed into the paper). Accessibility: one element, label "Photo"
(failure: "Photo, not loaded"), `.isImage`, id set by the caller. Never logs the URL.

## API / MCP changes
None (uses 014a via 014b).

## Accessibility identifiers
`editor.type`, `editor.<field>` (`front`, `back`, `photo`, `name`, `role`, `context`), `editor.photoPreview`,
`editor.direction.<prompt>-<answer>`, `editor.directionsHint`; `deck.row.<noteId>`, `deck.row.<id>.due`,
`deck.row.<id>.state`, `deck.row.<id>.photo`. Unchanged: `editor.save`, `editor.close`, `editor.discard`,
`editor.keepEditing`, `editor.error`, `editor.title`, `deck.*` from 009a.

## Out of scope
- Picking a photo from Photos/Contacts, uploading, cropping; validating that the URL loads.
- Per-card scheduling details in the deck (each direction's due date); a note-detail screen.
- Changing a note's type; free-form direction builder (only the catalog + existing extras).
