# 015 — Report a card

Status: ready
Owners: **015a** api-engineer, then **015b** ios-engineer (design-lead checks the design notes first).
Depends on: 014a (notes, merged). 015b also needs 010 (inline edit) and 011 (ratings) merged (same view, same
`canRate` rule). Backlog #31, #32.
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg (nothing new on screen at rest);
the menu is the system `.confirmationDialog` (Apple Mail / Photos action sheets).

## Goal
Agents write most cards. When the user meets a bad one while studying, they double-tap the revealed card, pick
what's wrong, and move on. The card leaves study at once. Later an agent with MCP access works through the
reports: it fixes the note, drops the card, or asks the user first.

## Decisions to confirm with the user
1. **Gesture**: double-tapping the revealed card **anywhere except an editable text** opens the menu. Double-tapping
   the front or back text still edits it (010). On a card with no inline edit (person or photo cards, 014d #9),
   double-tapping the text also opens the menu. Before reveal there's no menu: a double tap reveals (010 #1). Why:
   SwiftUI gives the more specific (child) gesture priority, so there's no new gesture to learn and no timing tricks.
2. **"Drop" is reversible.** Reporting holds the card out of study at once. The card is deleted only when an agent
   handles the report (`update_report` `deleted`). Until then, `kept` brings it back.
3. **"Drop" deletes the card, not the note.** Only that direction goes; its siblings stay. If it was the note's last
   card, the note goes too (same as `delete_card`).
4. **Failure is quiet.** If the report can't be sent, the card stays on screen and a line in the counter slot says
   "Couldn't send the report", so the user can retry. The screen doesn't switch to the offline screen, because the
   card is still fine to study.
5. **Confirmation**: "Reported" shows in the counter slot for 2 s, with a `.success` haptic. No toast or banner.
6. **No REST to list or close reports** for now. Only agents need that, through MCP. There's no reports screen in
   the app.
7. A held card **still counts** in `stats.total` and still shows in the Deck. Only study and the due counts skip
   it.

## Model (shared)
- **Report** = `{id, card_id, note_id, reason, comment, status, resolution, created_at, updated_at, resolved_at}`.
  - `reason`: `wrong | drop | doubt | rephrase | other`.
  - `comment`: required (trimmed, 1–500 chars) when the reason is `other`, otherwise optional.
  - `status`: `open | waiting_user | resolved | dismissed`.
  - `resolution`: the agent's last note (its question, or what it did).
  - `card_id` and `note_id` have **no foreign keys**, like `ReviewLog`, so a report outlives its card.
- **Held**: a card with any report whose status is `open` or `waiting_user` is out of the servable queue
  (`deck._queue`). That queue backs `/cards/due`, `due_cards`, `stats.due` and `stats.next_due`. A held card
  doesn't bury its siblings. Its FSRS state is never touched.

---

## 015a — API + MCP (api-engineer)

### REST
| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/cards/{id}/report` | `{"reason": "wrong", "comment": null}` (`comment` may be omitted) | `Report` (201) |

`Report` JSON: `{id, card_id, note_id, reason, comment, status, resolution, created_at, updated_at, resolved_at,
card}`. `card` is the current `Card`, or `null` once the card is deleted. An unknown card returns 404. A bad reason
or comment returns 422 `{"detail": …}`.

### MCP tools
- `list_reports(status: "active" | "all" | <one status> = "active")` returns `[Report]`, oldest first. `active` means
  `open` + `waiting_user`.
- `update_report(report_id, outcome, note)`. `note` is required and non-blank, and is stored as `resolution`.
  | `outcome` | Status | Card |
  |---|---|---|
  | `waiting_user` | `waiting_user` | stays held (the `note` is the question asked) |
  | `fixed` | `resolved` | back in study, schedule unchanged (fix the note first with `update_note`) |
  | `kept` | `dismissed` | back in study, unchanged (the card was right, or the user withdrew the report) |
  | `deleted` | `resolved` | deleted with `delete_card` semantics. If the card is already gone, this just closes the report |

  These calls raise a `ToolError`: an unknown report, or a report that's already `resolved` / `dismissed`.
- Add this paragraph to `INSTRUCTIONS`, as written:
  ```
  Reports. While studying, the user flags cards; a reported card is out of study until its report is
  closed. Work through `list_reports`, then close each with `update_report`:
  - wrong: fix the note (`update_note`), then `fixed`.
  - drop: `deleted` (removes that card only).
  - doubt: check it, show the user your evidence and change nothing until they confirm; then `fixed`
    or `kept`.
  - rephrase: ask the user how they want it; change nothing before they answer; then `fixed`.
  - other: read `comment`; ask the user if unclear.
  When you ask the user, first set `waiting_user` with your question as `note`.
  ```

### Acceptance criteria (015a, all pytest)
| # | Criterion |
|---|---|
| 1 | `POST /cards/{id}/report {"reason": "wrong"}` → 201, `status` `open`, `comment` null, `note_id` = the card's note, `card` = the card |
| 2 | `other` with a missing, empty or whitespace-only comment → 422. A comment over 500 chars → 422. An unknown reason → 422. An unknown card → 404. Comments are saved trimmed |
| 3 | After a report, the card is absent from `GET /cards/due`, MCP `due_cards` and `stats.due`, and `stats.next_due` ignores it. It's still in `GET /cards`, `GET /notes` and `stats.total`. A due sibling is still served |
| 4 | `list_reports()` returns the `open` and `waiting_user` reports, oldest first. `"all"` and a single status filter work. `card` is null when the card was deleted (`delete_note`) |
| 5 | `update_report` `waiting_user`: the status changes and `resolution` = note. The card stays held |
| 6 | `fixed` → `resolved` and `resolved_at` is set. The card is due again with its FSRS state unchanged. `kept` → `dismissed`, same for the card |
| 7 | `deleted` → the card is deleted (the note too if it was the last card). Its `ReviewLog` rows stay. The report is `resolved`. On a card that's already gone, it just closes the report |
| 8 | Unknown report id, a closed report, a blank note or an unknown outcome → `ToolError` |
| 9 | Two active reports on one card: the card stays held until both are closed |
| 10 | `INSTRUCTIONS` contains the reports paragraph. Tool docstrings say what each outcome does to the card |
| 11 | `docs/architecture.md`: the REST table row, the `report` table, the "held" rule and the two MCP tools |

---

## 015b — iOS (ios-engineer)

Mock = `LA_CARTE_API=mock`. Stub = `StubAPIServer` (records request bodies). "Double-tap the card" = on `study.card`
at normalized (0.08, 0.08), clear of the text.

### Acceptance criteria (015b)
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | On a revealed card, double-tapping the card opens a dialog titled "Report this card" with, in this order: "This is wrong", "I don't want this card", "I doubt this is correct", "I want it phrased differently", "Other…", and Cancel | unit + UI (light, dark) |
| 2 | Double-tapping `study.back` on a revealed basic card still opens `study.backField` (010 #3) and no dialog. Double-tapping an unrevealed card reveals it and opens no dialog (010 #1) | UI (regression) |
| 3 | `cardDoubleTapped` changes nothing while editing, while a review or report is in flight, or before reveal | unit |
| 4 | Cancel closes the dialog. The card stays revealed and nothing is sent | unit + UI |
| 5 | The first four choices send `POST /cards/{id}/report` with `wrong` / `drop` / `doubt` / `rephrase` and no `comment` key. The rating buttons are disabled while it's in flight | unit (all four) + UI (stub body, "This is wrong") |
| 6 | On success: the next card shows unrevealed and `study.remaining` decrements. `study.reportNotice` "Reported" takes the counter slot for 2 s, then `study.remaining` comes back | unit (`TestClock`) + UI |
| 7 | "Other…" opens an alert "What's wrong?" with the text field `study.report.comment`. `study.report.send` "Report" is disabled while the text is empty or whitespace. Typing " typo in the answer " and tapping Report sends `{"reason": "other", "comment": "typo in the answer"}`. Cancel sends nothing and leaves the card revealed | unit + UI |
| 8 | Reporting the last due card shows "All caught up", the same as rating it | unit + UI |
| 9 | When the report fails (stub 500, or offline): the card stays revealed, the buttons are enabled, `study.reportNotice` reads "Couldn't send the report", and the phase stays `.studying`. The next rating, edit or report clears it | unit + UI (stub) |
| 10 | A reported card doesn't come back on pull-to-refresh (`InMemoryAPIClient` holds it like the API). Refresh and foreground reloads are skipped while a report is in flight | unit + UI (mock) |
| 11 | `APIClient.reportCard` encodes the body as in #5 / #7 and accepts a 201 with the `Report` JSON (the body is ignored) | unit (`APIClientTests`) |
| 12 | Live (`scripts/e2e.sh`, runs last): the runner adds a card with `POST /cards`, the app refreshes, reveals it and reports "I don't want this card", then `GET /cards/due` from the runner doesn't include it | UI (`_liveAPI`) |

### Screens & states
Nothing new at rest. The new states:
- **Menu open**: the system confirmation dialog over the revealed card.
- **Comment alert**: an alert with one text field.
- **Notice**: `study.reportNotice` in the counter slot, styled like 010's `study.editError` (`.meta`, `secondaryInk`,
  no pink).

Screenshots: `study-report-menu` (light + dark), `study-report-other` (light), `study-reported` (light, notice
visible), `study-report-failed` (light), `study-report-live` (light, e2e).

### TCA shape
No new module. `StudyFeature` + `StudyView`, `APIClient`.
- `APIClient`: `reportCard: @Sendable (_ id: Card.ID, _ reason: ReportReason, _ comment: String?) async throws -> Void`.
  `ReportReason: String, Codable, CaseIterable` (`wrong, drop, doubt, rephrase, other`) goes in `Models.swift`. The
  in-memory client keeps a set of reported ids and leaves them out of `dueCards` and `stats.due`.
- State (new):
  ```swift
  var isReportMenuShown = false       // bound to .confirmationDialog
  var isReportCommentShown = false    // bound to the "Other…" alert
  var reportComment = ""
  var reportNotice: ReportNotice?     // .reported (2 s) / .failed; shown in the counter slot
  var canReport: Bool { canRate }     // 011: studying, revealed, not editing, nothing in flight
  enum ReportNotice: Equatable { case reported, failed }
  ```
  A report in flight sets **`isReviewing`**, the same flag a rating uses. One request about the current card runs
  at a time, so the buttons, the drag and refresh are all blocked with no new guard.
- Actions (new): `cardDoubleTapped`, `reportReasonTapped(ReportReason)`, `reportCommentSubmitted`,
  `reportResponse(Result<Void, any Error>, cardID: Card.ID)`, `reportNoticeExpired`. Bindings come through 010's
  `BindableAction`.
- Logic:
  - `cardDoubleTapped`: `guard canReport`, then `isReportMenuShown = true`.
  - `reportReasonTapped(.other)`: `reportComment = ""` and `isReportCommentShown = true`. Any other reason goes
    straight to the private helper `report(reason, comment: nil)`.
  - `reportCommentSubmitted`: trim. If the result is empty, do nothing. Otherwise hide the alert and call
    `report(.other, trimmed)`.
  - The `report` helper: `guard canReport` and `let card = cards.first`. Set `isReviewing = true`, clear
    `reportNotice` and `editFailed`, cancel the load (as `ratingTapped` does), then call `reportCard`.
  - `reportResponse` success: `isReviewing = false`, remove the card, `isRevealed = false`,
    `reportNotice = .reported`, and run a 2 s `continuousClock` sleep that sends `reportNoticeExpired`
    (`CancelID.notice`). If `cards` is now empty, fetch the due cards. Failure: `isReviewing = false` and
    `reportNotice = .failed`.
  - `reportNoticeExpired`: if the notice is `.reported`, set it to nil. A rating or an edit start sets
    `reportNotice = nil`.
- View: on `study.card`, `.gesture(TapGesture(count: 2).onEnded { store.send(.cardDoubleTapped) }, isEnabled:
  store.canReport)`. The text's own 010 double-tap stays on the child, so it wins there. This gesture is only on
  when revealed (where a single tap does nothing), so the single tap that reveals isn't delayed.
  - The menu: `.confirmationDialog("Report this card", isPresented: $store.isReportMenuShown, titleVisibility:
    .visible)` with five `Button`s that send `reportReasonTapped`.
  - The comment: `.alert("What's wrong?", isPresented: $store.isReportCommentShown)` with a `TextField` bound to
    `$store.reportComment`, Report (disabled when the text is blank) and Cancel.
  - Haptic: `.sensoryFeedback(.success, trigger: store.reportNotice) { _, new in new == .reported }`.
  - Add `.accessibilityAction(named: "Report")` on `study.card` when `canReport`. It's checked in review only (VoiceOver
    tests are deferred).
  - Vanilla SwiftUI presentation, not `ConfirmationDialogState`, so the buttons can carry ids and the alert can hold
    a text field.

### Accessibility identifiers
New: `study.report.wrong`, `study.report.drop`, `study.report.doubt`, `study.report.rephrase`, `study.report.other`
(the dialog buttons; if the system drops ids inside a dialog, QA queries by label), `study.report.comment`,
`study.report.send`, `study.reportNotice`. Kept: `study.card`, `study.front`, `study.back`, `study.remaining`.

### Design notes (design-lead to confirm)
The system dialog and alert as they are: no custom sheet, no icons, no pink. None of the reasons uses
`role: .destructive`, because all are reversible. The notice is the counter-slot text from 010 and fades with
`Theme.Motion.standard`.

---

## Out of scope
- A reports screen in the app, and REST endpoints to list or close reports (backlog #33).
- An MCP prompt `review_reports` (backlog #34).
- Reporting an unrevealed card, or from the Deck.
- Undoing a report from the app.
- Accessibility (VoiceOver) tests: deferred. Logo work.
