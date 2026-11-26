# 028 — Card list labels that match the study queue

Status: ready
Owners: api-engineer → ios-engineer → qa-validator
Design reference: docs/design/reference/04-list-dark.jpg (row meta line, unchanged layout)

## Goal
Each deck row says exactly what the study screen will do with that note: in the queue now, new, or
when it comes back. The server, which builds the queue, decides that; the app only puts it into words.

## Why (user report, 2026-11-25)
"Sometimes I see Due now, but I don't have it in my app." Investigation:

| # | Case | Code reason |
|---|---|---|
| 1 | The row label ignores the queue: it uses `note.due` = the earliest `due` of the note's cards and only compares it to the device clock | `ios/LaCarteKit/Sources/DeckFeature/DeckView.swift:203-208`, `DeckFeature.swift:243-245` |
| 2 | A sibling of a card reviewed in the last 6 h is buried (not served) while its own `due` has passed: "Due now" on the row, nothing in Study | `api/src/la_carte_api/deck.py:569-579` (`SIBLING_BURY`, `deck.py:61`) |
| 3 | A card with an active report is out of the queue entirely, but its row still says "Due now" | `deck.py:552-562` |
| 4 | Every card that was never studied is created `due = now` (`deck.py:360-365`), so all of them say "Due now". Study serves them only after every review (`deck.py:581-591`), and the counter shows steps of 15 new (`StudyFeature/Ladder.swift:37-39`), so it looks like a daily cap. There is no cap: the ladder is display only (`Ladder.swift:4`, `models.py:347`) | as listed |
| 5 | The queue has no day boundary: it compares exact times (`deck.py:594`), so a card due at 22:00 is not served at 09:00. Labels that say "Today" have to say "Later today" | `deck.py:594` |

Checked and not a cause: Study fetches 100 cards at a time (`StudyFeature.swift:560`) but fetches again
as soon as the batch is empty (`StudyFeature.swift:341`), so no due card is left out. Device and server
clocks can differ by a few seconds; that doesn't matter.

## User stories
- As the user, I read a row and know whether Study will show it now, and if not, when.
- As the user, I can tell new cards from reviews waiting for me, without "Due now" on 200 rows.

## Label rules (iOS, from `note.next`)
`now` = the device clock when the row is drawn; days = calendar days in the device's calendar and time zone
(the same local day `/stats?tz=` uses). `d` = days from the start of today to the start of `ready_at`'s day.

| Condition (first match) | Label |
|---|---|
| `next` is `null` (every card of the note has an active report) | `Reported` |
| `ready_at <= now` and the `next` card's state is `new` | `New` |
| `ready_at <= now` | `In queue` |
| `d == 0` | `Later today` |
| `d == 1` | `Tomorrow` |
| `2 <= d <= 13` | `In d days` |
| `14 <= d <= 59` | `In w weeks`, `w = d / 7` rounded down |
| `60 <= d <= 364` | `In m months`, `m = d / 30` rounded down |
| `d >= 365` | `In y years`, `y = d / 365` rounded down; `In 1 year` singular |

A note whose next card is new but buried (case 2) shows its time (`Later today`), not `New`.
The right side of the meta line keeps `N directions` for notes with 2+ cards and shows nothing for a
one-card note: the raw FSRS state (`new`, `review`, `relearning`) duplicated the new label and was jargon.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `GET /notes`, `GET /notes/{id}`, `POST /notes`, `PATCH /notes/{id}` and MCP `list_notes` / `add_notes` / `update_note` return every note with `next`: `{card_id, ready_at}` or `null` | pytest |
| 2 | **One source of truth**: on a deck mixing new, review, learning, relearning, buried siblings and reported cards, at a fixed `now`: the notes with `next.ready_at <= now` are exactly the notes of `due_cards(limit=all)`, and for each such note `next.card_id` is the card `due_cards` serves for it | pytest |
| 3 | For the same deck, `stats.due` equals the number of notes with `next.ready_at <= now` | pytest |
| 4 | A new note's `next` is its first card in queue order with `ready_at` = its `due` (≤ now) | pytest |
| 5 | Reviewing one card of a two-direction note `Good` at `t`: the note's `next` is the sibling with `ready_at = min(t + 6 h, reviewed card's new due)`, or the reviewed card if it is ready earlier; never a time ≤ `t` while the bury holds | pytest |
| 6 | A one-card note with an active report has `next: null`; once the report is resolved/dismissed, `next` is back. A two-card note with one reported card has `next` = the other card | pytest |
| 7 | When no card of a note is ready, `next` is the card with the earliest `ready_at` (bury applied; ties by queue order) | pytest |
| 8 | `Note` decodes `next` (object), `next: null` and a missing `next` key (older server → `nil`, label falls back to rule 9) | unit (DecodingTests) |
| 9 | The label function returns each label of the table, tested with a fixed `now` and calendar (Europe/Paris): `Reported`, `New`, `In queue`, `Later today`, `Tomorrow` (now 23:30, ready 00:30 next day), `Later today` (now 00:10, ready 23:50), `In 3 days`, `In 2 weeks` (d = 20), `In 4 months` (d = 125), `In 1 year` (d = 400). A missing `next` key (server older than 028) decodes as the note's earliest-due card, ready at its `due`, so the same rules apply (`New` / `In queue` when past, a day label otherwise; never `Reported`) | unit |
| 10 | The in-memory API (`InMemoryAPIClient`) fills `next` with the same rules as the server (held → `null`, 6 h sibling bury, learning first, then by due), so mock UI runs match Study | unit |
| 11 | `deck.row.<id>.due` shows the label; `deck.row.<id>.state` exists only for notes with 2+ cards and reads `N directions` | UI |
| 12 | Mock deck `LA_CARTE_API=mock`: every row reads `New`. Rate the first card `Good` in Study, open the deck: its row reads `Tomorrow`, the others still `New` | UI |
| 13 | Mock deck `mock-notes`: rate the first direction of "la carte", open the deck: its row reads `Later today` or `Tomorrow` (6 h bury, clock-dependent), never `In queue` or `New` | UI |
| 14 | Report a card of a one-card note from Study, open the deck: its row reads `Reported` | UI |
| 15 | Mock deck `LA_CARTE_API=mock-labels` (new, see below) shows one row per label: `In queue`, `New`, `Later today`, `Tomorrow`, `In 3 days`, `In 2 weeks`, `In 4 months`, `Reported` | UI + screenshot |

## Screens & states
Deck list only; layout unchanged, only the meta line's texts change.
Screenshots (light + dark): `deck-labels` (the `mock-labels` deck, all rows visible), `deck-after-rating`
(AC 12).

`LA_CARTE_API=mock-labels` (ios-engineer, `InMemoryAPIClient` fixtures, documented in `LiveAPIClient.liveValue`'s
comment): eight basic one-card notes, relative to launch time: a review due 1 h ago (`In queue`), a new card
(`New`), a learning card due in 30 min (`Later today`; a run after 23:30 may see `Tomorrow`), a review due tomorrow at noon, in 3 days, 20 days, 125 days,
and a reported review (held). Fronts in English, e.g. "in queue", "new", etc., so screenshots read clearly.

## TCA shape (iOS)
- Module: `DeckFeature` (unchanged composition). No new State, Action or dependency: the label is display
  formatting of server data, like today's `dueText`.
- Replace `DeckView.dueText(_:now:locale:)` with a pure `Note.queueLabel(now: Date, calendar: Calendar) -> String`
  (in `DeckFeature`, unit-tested); the view calls it with `.now` and `.current`.
- `Note.stateText` becomes `String?`: `"N directions"` for 2+ cards, else `nil` (the view omits the text).
- Remove `Note.due` (`DeckFeature.swift:243`) if nothing else uses it; the fallback for a missing `next` lives
  inside `queueLabel`.
- `APIClient` module: `Note.next: Note.Next?` with `struct Next: Codable, Equatable, Sendable { cardId: UUID; readyAt: Date }`;
  `Note.init` gains `next: Next? = nil`. `InMemoryAPIClient` computes it per AC 10 whenever it returns notes.
- Delegate actions: none. The deck already reloads on appear and foreground, so the labels are fresh each
  time the deck opens; no live ticking while it stays open.

## API / MCP changes
`NoteRead` gains one field (all note responses, REST and MCP):
```json
{"id": "…", "type": "basic", "fields": {…}, "cards": [{…}],
 "next": {"card_id": "65f15766-7ab3-4c84-bb05-ae180e083bef", "ready_at": "2026-11-25T14:02:11Z"},
 "created_at": "…", "updated_at": "…"}
```
`next` = the card of this note Study will serve first and when: among the note's non-held cards, the first in
queue order whose ready time is ≤ now; otherwise the one with the earliest ready time. `null` when every card is
held by an active report.

Implementation (api-engineer): split `deck._queue` so one function yields every non-held `(card, note, ready_at)`
in queue order (held filtering, sibling bury, `order` unchanged); `_queue` builds the servable list from it and
`_note_reads` derives `next` from it, with one `now = utcnow()`. No scheduling change, no new endpoint, `CardRead`
and `/stats` unchanged. Update `docs/architecture.md` (the `/notes` row and the burying paragraph: "`Note.next`
reads the same queue, spec 028") and the MCP `list_notes` description ("`next.ready_at` <= now = in the study
queue now; `null` = reported").

## Accessibility identifiers
- `deck.row.<id>.due`: the queue label (existing id, new texts).
- `deck.row.<id>.state`: `N directions`, only on 2+ card notes (existing id; absent on one-card notes).

## Order of work
1. api-engineer: `next` + pytest (AC 1-7), architecture doc + MCP description.
2. ios-engineer: model + DecodingTests + label + mock (AC 8-10), after step 1 merges (or against the JSON above).
3. qa-validator: AC 11-15; update existing asserts that expect `Due now` / `new` on rows
   (`DeckUITests.swift:28, 61, 224, 334`, `NotesUITests.swift:237`, helper at `NotesUITests.swift:842`).

## Out of scope
- A daily new-card cap: there isn't one and this spec doesn't add one (021's ladder stays display only).
- Live ticking of labels while the deck stays open (backlog 39 covers live update).
- Sorting or filtering the list by label.
- Showing `next` on the widget or in Study.
- `CardRead` / `GET /cards` (the app's list uses notes).
