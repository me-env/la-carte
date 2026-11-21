# QA: 014c Notes in the Deck + note editor

Verdict: **FAIL** (direction rows: wrong id + labels; unit tests don't compile after the main merge)
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-a49c6e2d8c3e3ec0b` (82895e0 + main merged)
Runs: `qa/screenshots/final/` (full suite), `qa/screenshots/final-rerun/`, `qa/screenshots/final-e2e/`
Commands: `UI_WORKERS=1 scripts/ios-ui-test.sh --split 3 final` (❌ 67 passed, 6 failed, 9 skipped, 12.6 min),
`--split 3 final-rerun` (failed tests again), `scripts/e2e.sh final-e2e` (❌ 8/9: only the 014d photo-failure bug), `scripts/ios-test.sh` (❌ build, bug 2)
Test fixes for notes (not app bugs): `testDeck_rowsFromAPI` and `testDeck_pullToRefresh` now expect `GET /notes`; the live
pull test uses the card's `note_id` as the row id; the deck spinner check skips the system keyboard's blue Search key.
Tests: `NotesUITests` (new: `testNotesDeck_listAndSearch`, `testNoteEditor_personCreateEditDelete`,
`testNoteEditor_personCreateDelete_liveAPI`); `StubDeck` now serves `/notes` and a made-up PNG at `/photos/*.png`.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | 4 rows in mock-notes, `deck-notes-{light,dark}.png`; stub deck lists via `GET /notes?limit=500` (`testDeck_rowsFromAPI`) |
| 2 | PASS | person row: name / description, "Due now", "3 directions"; la carte "2 directions" (`deck-notes-*.png`) |
| 3 | PASS | `deck.row.<id>.photo` labelled "Photo" (loaded), 44 pt circle left of the text, centered (`deck-notes-*`, `deck-person-added-*`) |
| 4 | PASS | "bakery" leaves only the person, `deck-notes-search-light.png` |
| 5 | PASS | swipe Delete → `DELETE /notes/{id}`, row gone (stub test) |
| 6 | PASS | tapping the person row opens "Edit person", prefilled (`editor-person-edit-*.png`) |
| 7 | PASS | segmented Basic/Person, Basic default, switching swaps fields; no picker when editing (`editor-basic-new-*`, `editor-person-new-*`) |
| 8 | PASS | `editor.photo/name/description`; live preview loads the stub photo (`editor-person-filled-*.png`, label "Photo") |
| 9 | **FAIL** | bug 1: ids/labels differ from the spec |
| 10 | PASS | new basic: front-back on, back-front off; new person: none on |
| 11 | PASS | all three person rows disabled while fields are empty |
| 12 | PASS | Save off for an empty person, on with name + 2 directions; hint "Choose at least one direction" |
| 13 | PASS (UI side) | POST body `type person`, fields, prompts `[photo]`,`[description]`; PATCH `/notes/{id}` with the full set `[photo]`,`[name]` and the new description |
| 15 | PASS | nav titles "New card" / "New person" / "Edit person" |
| 16 | PASS | `testStudy_addWhenCaughtUp` / `testDeck_changesRefreshStudy` green |
| 17 | PASS | `testNoteEditor_personCreateDelete_liveAPI` in `final-e2e`: `GET /notes` has the person with 2 cards, deck delete → `GET /notes/{id}` 404 (`final-e2e/deck-person-live-light.png`) |
| 14, 18 | unit / review | not UI |
| 19 | deferred | text size checks deferred (docs/testing.md) |

## Visual review
- [x] background edge to edge, light + dark; rows on `surface`, radius 12
- [x] photos render: thumbnails in rows, 88 pt preview in the editor, light + dark
- [x] nothing pink except the cursor; checkmarks ink
- [ ] direction labels not as designed (bug 1); description placeholder differs (bug 3)
- Note: the photo URL field is two lines tall even with a one-line URL (`editor-person-filled-dark.png`); minor.

## Bugs
1. **Person direction rows: id and label don't match spec 014c #9.** New note → Person → Directions. Expected ids
   `editor.direction.photo-name+description`, `name-photo+description`, `description-name+photo`, labels
   "Photo → Name + Description", "Name → Photo + Description", "Description → Name + Photo". Actual: third id is
   `editor.direction.description-photo+name` (`NoteEditorView.identifier` uses field order); labels are only the
   prompt field ("Photo", "Name", "Description"), footer "Each direction is its own card: it shows that field and asks for
   the rest." (spec: "Each direction is its own card."). `editor-person-new-directions-light.png`, `editor-person-edit-light.png`.
2. **`scripts/ios-test.sh` doesn't compile after merging main.** `ios/LaCarteKit/Tests/AppFeatureTests/ScreenColorTests.swift`
   (from main) uses the old API: line 8 `import CardEditorFeature`, line 68 `DeckFeature.State.cards`, lines 88–89
   `CardEditorFeature.State(card:)` / `CardEditorView`. Port to `NoteEditorFeature`, `state.notes = [Note].fixtures`,
   `NoteEditorFeature.State(note:)` / `NoteEditorView`.
3. **Description placeholder** reads "Who they are, e.g. what they do"; design notes say "Role, or how you know them".
   Minor (`editor-person-new-light.png`).
