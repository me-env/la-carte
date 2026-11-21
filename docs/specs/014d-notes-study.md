# 014d — Notes: study a card's direction (photo on the card face)

Status: ready (blocked: starts after 011 and 014b merge; Study lane, one spec at a time; design-lead notes first)
Owners: ios-engineer (design-lead notes first)
Depends on: 014b (card fields + `mock-notes`), 014a deployed (live API), 011 (ratings) merged.
Shared model: [014](014-notes.md). Backlog #30.
Design reference: docs/design/reference/01-editor-dark.jpg, 02-editor-light.jpg (one centered thing); Apple
Contacts poster / Photos for the photo treatment.

**Parallelism.** Touches `StudyFeature/**` and `StudyFeatureTests`, plus a `CardPhoto` view in `DesignSystem/` if
design-lead's notes call for a shared one (014c's deck thumbnail can then reuse it: whichever lands second adopts
it). Study lane is strictly serial: 011 (in flight) → this, 009c and 013 step 2 in the order the manager picks.
Parallel to 014c.

## Goal
Study shows each card's own angle: the prompt fields on the front (a person's photo, or what they do, or a word),
the answer fields after reveal. Siblings never follow each other (burying is server-side).

## Acceptance criteria
Mock = `LA_CARTE_API=mock-notes` (014b); person cards are due first.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | The front shows the card's `prompt` fields from `fields`, in order; the back (after `study.reveal`) shows its `answer` fields. `front`/`back` strings are no longer read by Study | unit + UI |
| 2 | Text fields: the first prompt text field uses `.cardFace`; further prompt fields and all answer fields use today's back style, one line block per field | UI |
| 3 | A `photo` field renders as an image (`study.photo`) with `AsyncImage`: a fixed frame during loading, success and failure (no layout jump); failure shows a placeholder symbol in `secondaryInk` and the card can still be revealed and rated | UI (mock: loaded; live E2E: an unreachable URL → placeholder) |
| 4 | `photo → name` card: before reveal only the photo is visible (no name anywhere on screen or in the accessibility tree); the photo's accessibility label is "Photo" | UI |
| 5 | A `person` card shows a quiet hint under the prompt naming what to recall, from its answer fields' labels (`study.answerHint`, e.g. "Name · Role"). `basic` cards show no hint (today's look unchanged) | unit + UI |
| 6 | On reveal, a `person` card shows the note's `context` under the answer (`study.context`, `.meta`) when present and not already one of the card's fields | UI |
| 7 | A `back → front` card ("la carte" reverse) shows "the menu — and the map" on the front and "la carte" after reveal | UI |
| 8 | After rating the person's `photo → name` card, the next card is not its `role → name` sibling (in-memory burying, 014b) | UI |
| 9 | Inline edit (010) is offered only when the card's prompt and answer are each exactly one text field (every basic card, `role → name`); it saves through `updateCard` (shown sides, 014a), and the card's `fields` update. On a photo or multi-field card a double-tap does nothing | unit |
| 10 | Dynamic Type at AX sizes: the photo scales down to keep prompt + rating row on one screen (cap per design notes); text reflows as today | UI (AX5) |
| 11 | Live E2E: a person note created via `POST /notes` (photo URL pointing to the local test server or unreachable) is studied in the app: prompt, reveal, rate; then its sibling is absent from `GET /cards/due` | UI (`_liveAPI`) |

## Screens & states
Screenshots (light + dark): `study-person-photo` (prompt), `study-person-photo-revealed` (name + context),
`study-person-role` (role → name), `study-reverse` ("la carte" back → front, revealed), `study-photo-failed` (live),
`study-person-ax5` (light).

## TCA shape (iOS)
- No new state or actions. `Card` already carries `type`, `prompt`, `answer`, `fields` (014b).
- Derived (reducer-side, so the view has no logic): `answerHint: String?` (person only), `context: String?`,
  `canEditInline: Bool` (gates 010's `cardTapped` double-tap path).
- `dueCards`, `review`, `stats` calls unchanged; burying needs nothing on the device.

## Design notes (design-lead, before engineering)
"One thing on screen": on a photo prompt the photo **replaces** the centered word. Uses `CardPhoto(.card)` (014c
notes: shared view, hairline placeholder, `person.fill` failure symbol, fixed frame, 1 pt hairline stroke).
No accent anywhere on the card; the only pink stays `study.remaining` (rule 4).

- **Photo:** centered where `.cardFace` text sits, width `min(Theme.Photo.card, 60% of the card width)` = 240 pt
  on an iPhone 17 Pro, 4:5 portrait (300 pt tall), `Theme.Radius.photo` (20, continuous). It sits inside the
  `study.front` container, so it moves with 011's drag; the ink-dot ring draws on top, unchanged. Success fades in
  with `Theme.Motion.standard` (Reduce Motion: appears). Loading and failure keep the same frame, so nothing moves.
- **Other prompt fields** (`photo → name + role` has none; `role → name` has the role): first text field
  `.cardFace` ink, further ones `.body` `secondaryInk`, `Theme.Spacing.s` apart.
- **Answer hint** (`study.answerHint`, person only): `.meta`, `secondaryInk`, sentence wording from the answer
  labels, a question: "Name?", "Name and role?" (`ListFormatter`, first word capitalized; overrides #5's
  "Name · Role" example). It shares **one slot** with the answer: a `ZStack` in the `study.back` position sized by
  the larger child; on reveal the hint fades out as the answer fades in (`Theme.Motion.standard`; Reduce Motion:
  instant swap). The slot is always laid out, so the prompt never moves (today's rule). Hidden from VoiceOver
  after reveal.
- **Answer fields** (name + role): one line block per field, today's back style (`.body`, `secondaryInk`),
  `Theme.Spacing.xs` apart, in display order; no labels ("Name:") on the card.
- **Context** (`study.context`): under the answer, `Theme.Spacing.s` gap, `.meta`, `secondaryInk`, wraps
  (no line limit; the card scrolls as today). Revealed with the answer (same opacity), never before.
- **AX sizes:** when `dynamicTypeSize.isAccessibilitySize`, the photo drops to `Theme.Photo.cardCompact` (160 pt
  wide, 200 tall), so photo + hint + rating row fit one screen at AX5 (text stays capped at `.accessibility2`).
- **Dark/forest:** same view, no extra treatment; the hairline stroke keeps dark-edged photos off the paper.
- Inline edit off (#9): double-tap on a photo or multi-field card does nothing, no haptic.

## API / MCP changes
None.

## Accessibility identifiers
New: `study.photo`, `study.answerHint`, `study.context`. Unchanged: `study.front`, `study.back` (now containers
of the prompt / answer fields), `study.card`, `study.reveal`, `study.rate.*`, `study.remaining`, 010/011 ids.

## Out of scope
- Prefetching photos of upcoming cards; zooming the photo.
- Typing the answer; partial credit per answer field (one rating per card).
- Inline edit of photo or multi-field cards (use the deck editor).
