# 027 — Note editor: new basic notes check both directions

Status: ready
Owners: ios-engineer → code-reviewer → qa-validator
Depends on: 014c (note editor) merged. Pairs with [026](026-both-directions-default.md) (server default).
Amends: [014c](014c-notes-deck-editor.md) AC 10 and the "never automatic reverse" wording. Backlog #52.
Design reference: none new; the editor's Directions section from 014c (design notes 4) is unchanged.

## Goal
A new basic note made in the app gets both cards, front → back and back → front, like one an agent adds
without directions (026). The user unchecks a direction when the reverse isn't a meaningful question.

## User stories
- As the user, I add "chat" / "cat" from the app and can recall it both ways without touching the directions.
- As the user, I add "Capital of France?" / "Paris", uncheck "Back → Front", and get one card.

## Decisions
1. **Only the new-note default changes.** `NoteType.basic.defaultDirections` becomes
   `[front → back, back → front]`. It already drives the new-note state, the Person → Basic switch (014c AC 7)
   and "unchanged" for discard protection (014c AC 14), so all three follow with no other logic.
2. **Existing notes keep their directions.** Editing prefills `note.cards` directions as today; opening a
   one-card note never adds the reverse.
3. **person unchanged**: a new person still starts with no direction on.
4. **No API or contract change.** The editor still sends explicit `directions` (`NoteDraft`), now with two for
   a default basic note. No `APIClient` / `DecodingTests` change.
5. **Unchecking works as today.** A direction that is on is never disabled (014c AC 11), so either default
   check can be removed while the fields are still empty. Turning one back on needs its fields filled (unchanged).

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `NoteEditorFeature.State()` (new note): type basic, both fields empty, `directions` = `front → back` and `back → front` in catalog order, `hasChanges == false` (replaces 014c AC 10 for basic) | unit (TestStore / state) |
| 2 | Filling front "chat" and back "cat" on a new note, then Save, calls `addNote` with a draft whose `directions` are exactly `[front → back, back → front]` | unit (TestStore) |
| 3 | Unchecking `back-front` (`directionToggled`) on a new basic note with empty fields removes it; `front-back` stays on; Save after filling both fields sends exactly `[front → back]`. Same for unchecking `front-back` (sends `[back → front]`) | unit (TestStore) |
| 4 | Unchecking both leaves `directions` empty, `canSave == false`, and `editor.directionsHint` reads "Choose at least one direction" (unchanged rule) | unit + UI |
| 5 | Editing an existing basic note with one card `front → back` shows only `front-back` on; saving a field edit sends `[front → back]` (no reverse added) | unit (TestStore) |
| 6 | New note → Person → Basic: back on Basic, both basic directions are on again | unit (TestStore) |
| 7 | New person: no direction on (unchanged, 014c AC 10) | unit + UI |
| 8 | A new basic note with only the default directions and empty fields closes without the discard prompt; unchecking one counts as a change (014c AC 14) | unit |
| 9 | UI (mock stub): `deck.add` → "New card": `editor.direction.front-back` and `editor.direction.back-front` are both selected. Screenshot `editor-basic-new` (light + dark) | UI |
| 10 | UI (mock stub): fill `editor.front` "chat", `editor.back` "cat", Save → the new row's `deck.row.<id>.state` reads "2 directions" | UI |
| 11 | UI (mock stub): `deck.add`, tap `editor.direction.back-front` → it is no longer selected, `front-back` still is; fill both fields, Save → the new row's state reads "new" (one card). Screenshot `editor-basic-one-direction` (light) before Save | UI |
| 12 | UI: opening an existing one-card basic row shows `editor.direction.front-back` selected and `editor.direction.back-front` not selected | UI |
| 13 | `scripts/ios-test.sh` passes; unit tests that asserted the old single default (`aNewNoteIsBasicWithOnlyFrontToBackOn`, the `fieldChanged` directions in `AppFeatureTests` add flow and `DeckFeatureTests` add flow) are updated to the new default, not deleted | unit + review |

## Screens & states
No layout change. Screenshots: `editor-basic-new` (both checks; light + dark, retaken),
`editor-basic-one-direction` (`back-front` unchecked; light).

## TCA shape (iOS)
- Module: `NoteEditorFeature` only. No new state, action, dependency or delegate.
- Change: `NoteType.defaultDirections` for `.basic` returns both directions; its doc comment says basic starts
  with both, person with none.

## API / MCP changes
None (decision 4).

## Accessibility identifiers
Existing, unchanged: `editor.type`, `editor.front`, `editor.back`, `editor.direction.front-back`,
`editor.direction.back-front`, `editor.directionsHint`, `editor.save`, `editor.close`, `deck.add`,
`deck.row.<id>`, `deck.row.<id>.state`. Selection is read with `isSelected` (checkmark rows carry `.isSelected`).

## Notes for QA (existing UI tests)
Tests that add a basic note and assert one card must tap `editor.direction.back-front` off before Save
(one tap, existing assertions stay valid; also covers AC 3 end to end):
`DeckUITests.testDeck_addFromDeck`, `testStudy_addWhenCaughtUp`, `testDeck_changesRefreshStudy`,
`testDeck_addFromStudyThenDelete_liveAPI`. `NotesUITests.testNoteEditor_personCreateEditDelete` flips its
`back-front` assertion (AC 9). `StubAPIServer.store` already keeps a two-card basic note as a note.

## Out of scope
- Server default and MCP wording (026).
- Backfilling reverse cards on existing notes.
- person defaults; a setting for the default.
