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
Study shows each card's own angle: the prompt fields on the front (a person's photo, name or description, or a word),
the answer fields after reveal. Siblings never follow each other (burying is server-side).

## Acceptance criteria
Mock = `LA_CARTE_API=mock-notes` (014b); person cards are due first.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | The front shows the card's `prompt` fields from `fields`, in order; the back (after `study.reveal`) shows its `answer` fields. `front`/`back` strings are no longer read by Study | unit + UI |
| 2 | Text fields: the first prompt text field uses `.cardFace`; further prompt fields and all answer fields use today's back style, one line block per field | UI |
| 3 | A `photo` field renders as an image (`study.photo`) with `AsyncImage`: a fixed frame during loading, success and failure (no layout jump); failure shows a placeholder symbol in `secondaryInk` and the card can still be revealed and rated | UI (mock: loaded; live E2E: an unreachable URL → placeholder) |
| 4 | `photo → name` card: before reveal only the photo is visible (no name anywhere on screen or in the accessibility tree); the photo's accessibility label is "Photo" | UI |
| 5 | A `person` card shows a quiet hint under the prompt naming what to recall, from its answer fields' labels (`study.answerHint`, e.g. "Name · Description"). `basic` cards show no hint (today's look unchanged) | unit + UI |
| 6 | *Amended 2026-11-21 (user):* no separate context line. On reveal, a `person` card shows every other non-empty field (the answer): the photo as an image (`study.photo`) and name/description as text | UI |
| 7 | A `back → front` card ("la carte" reverse) shows "the menu — and the map" on the front and "la carte" after reveal | UI |
| 8 | After rating the person's `photo → name` card, the next card is not its `description → name + photo` sibling (in-memory burying, 014b) | UI |
| 9 | Inline edit (010) is offered only when the card's prompt and answer are each exactly one text field (every basic card; no person card, whose answers have several fields); it saves through `updateCard` (shown sides, 014a), and the card's `fields` update. On a photo or multi-field card a double-tap does nothing | unit |
| 10 | Dynamic Type at AX sizes: the photo scales down to keep prompt + rating row on one screen (cap per design notes); text reflows as today | UI (AX5) |
| 11 | Live E2E: a person note created via `POST /notes` (photo URL pointing to the local test server or unreachable) is studied in the app: prompt, reveal, rate; then its sibling is absent from `GET /cards/due` | UI (`_liveAPI`) |

## Screens & states
Screenshots (light + dark): `study-person-photo` (prompt), `study-person-photo-revealed` (name + description),
`study-person-description` (description → name + photo, revealed with the photo), `study-reverse` ("la carte" back → front, revealed), `study-photo-failed` (live),
`study-person-ax5` (light).

## TCA shape (iOS)
- No new state or actions. `Card` already carries `type`, `prompt`, `answer`, `fields` (014b).
- Derived (reducer-side, so the view has no logic): `answerHint: String?` (person only), 
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
- **Other prompt fields** (`photo → …` has none; `description → …` has the description; `name → …` has the name): first text field
  `.cardFace` ink, further ones `.body` `secondaryInk`, `Theme.Spacing.s` apart.
- **Answer hint** (`study.answerHint`, person only): `.meta`, `secondaryInk`, sentence wording from the answer
  labels, a question: "Name and description?", "Name and photo?" (`ListFormatter`, first word capitalized; overrides #5's
  "Name · Description" example). It shares **one slot** with the answer: a `ZStack` in the `study.back` position sized by
  the larger child; on reveal the hint fades out as the answer fades in (`Theme.Motion.standard`; Reduce Motion:
  instant swap). The slot is always laid out, so the prompt never moves (today's rule). Hidden from VoiceOver
  after reveal.
- **Answer fields** (every other non-empty field; a photo answer uses `CardPhoto(.card)` like a photo prompt): one line block per text field, today's back style (`.body`, `secondaryInk`),
  `Theme.Spacing.xs` apart, in display order; no labels ("Name:") on the card.
- **Context line removed** (*amended 2026-11-21 (user)*): `description` is an ordinary field, shown as prompt or answer.
- **AX sizes:** when `dynamicTypeSize.isAccessibilitySize`, the photo drops to `Theme.Photo.cardCompact` (160 pt
  wide, 200 tall), so photo + hint + rating row fit one screen at AX5 (text stays capped at `.accessibility2`).
- **Dark/forest:** same view, no extra treatment; the hairline stroke keeps dark-edged photos off the paper.
- Inline edit off (#9): double-tap on a photo or multi-field card does nothing, no haptic.

### Person card text: centred caption, the name first (design 2026-11-22 per user)
User, on device (photo → name + description): the hint sat bottom left and vanished on reveal; "centre it below
the image"; "centre the person's name below the image, and make it stand out a bit more than the description".
Cause today: the answer's alignment is measured on all answer text joined ("Ada Example runs the bakery…"), so a
3+-line description makes the whole slot leading, hint and name included, and the hint is centred vertically in
a slot sized by the answer, so it floats mid-slot. Name and description share one style, `secondaryInk`.
Mock (tokens only, rendered next to today's `StudyView`): scratch `person-light-before-after.png` /
`person-dark-before-after.png` (design-lead's report). Applies to `type == .person` only; basic cards unchanged.

The **photo is the axis**: on a person card, the photo, the name and the hint are always centred on the column,
whatever the other fields' alignment. Like a Contacts poster or a Photos caption, the caption sits under the
picture: name, then description.

| Element | Font | Colour | Alignment | Spacing |
|---|---|---|---|---|
| Hint (before reveal) | `.subheadline` (was `.meta`: the user looks for it, and it is the only text on a photo prompt) | `secondaryInk` | centred | top of the answer slot, `Theme.Spacing.m` under the prompt (the stack's existing gap) |
| Name, in the answer | `.cardFaceSmall` (title2 medium) | `ink` | always centred (`multilineTextAlignment(.center)`), wraps, never truncated, never measured | `Theme.Spacing.m` under a photo; first in the slot otherwise |
| Description, in the answer | `.body` (`CardFont.body`) | `secondaryInk` | in the caption block (below): 1-2 lines centred, 3+ leading | `Theme.Spacing.xs` under the name; `Theme.Spacing.m` under a photo |
| Photo, in the answer | `CardPhoto(.card)` | — | centred | first in the slot |
| Name or description as the **prompt** | spec 017 tier (`CardText.promptFont`), unchanged | `ink` | spec 017, unchanged | — |

- **Hint: cross-fades into the answer in the same place.** The slot is a `ZStack(alignment: .top)` (was
  `.center`) with the hint centred horizontally (its own `frame(maxWidth: .infinity)`), so the hint sits where the
  answer's first element starts: the name's line on a photo prompt, the photo's top edge on a text prompt. On reveal
  the hint fades out as the answer fades in (`Theme.Motion.standard`; Reduce Motion: instant swap), as today; it
  does not stay after reveal (the answer replaces the question it asked). The slot stays laid out at the answer's
  size, so the prompt never moves (spec 017 rule 8 and #13 hold: nothing above the slot depends on it).
- **Name stands out:** `.cardFaceSmall` ink is one tier under the card face, so on `description → photo + name`
  a short description prompt (34 pt, `.cardFace`) still leads; under a long one (`.cardFaceSmall`) the two share a
  size and the photo between them separates them. The question still leads (017 rule 2); the name leads the
  answer. A deliberate exception to rule 2's "answer in `secondaryInk`": a person card's answer has a headword.
  No new token.
- **Description:** `.body` `secondaryInk` always (not 017's `.cardAnswer` tier: a caption under a 22 pt name must
  read as secondary even when short). Contrast: `secondaryInk` light is 2.6:1, a known global issue (017 out of
  scope) shared by every answer. Not patched here: the name now carries the fact in `ink`, and a one-off stronger
  grey would make two answer greys. The token fix is a separate design-lead follow-up (backlog).
- **Answer container:** the answer `VStack(alignment: .center)` takes `frame(maxWidth: .infinity)` (centred in the
  full column), so the slot never shrinks to its content; on a person card the slot ignores 017's
  `answerAlignment`/`answerWidth`/snap (they stay for basic cards).
- **Long description, the caption block (spec 017 rule 3 applied to the description alone):** the description is
  laid out in a block of width `min(column, photoWidth + 2 × Theme.Spacing.l)`, centred, where `photoWidth` is the
  `CardPhoto(.card)` width in use (`Theme.Photo.card` = 240 → 288 pt; `Theme.Photo.cardCompact` at AX sizes). The
  answer probe measures **the description field alone** in that same width, font `.body` at the current Dynamic
  Type size (capped at `.accessibility2` like all card text), not name + description joined and not 017's
  `.cardAnswer`. 1-2 rendered lines: centred, line by line. 3+: leading inside the block
  (`frame(maxWidth: .infinity, alignment: .leading)` within the block's width), so the paragraph reads as one
  centred caption under the photo and the name, not a full-width paragraph under a centred headword. The name and
  the photo stay centred either way. A description *prompt* is unchanged (017: full column).
- **Directions, same hierarchy everywhere:**
  - `photo → name + description`: photo · hint ("Name and description?") → name (`.cardFaceSmall` ink) ·
    description (`.body` secondary). No description: photo · hint "Name?" → name alone.
  - `name → photo + description`: name (017 prompt tier, ink, the largest text) · hint → photo · description.
  - `description → photo + name`: description (017 prompt tier, ink; 3+ lines leading per 017) · hint → photo ·
    name (`.cardFaceSmall` ink, centred even under a leading description: the photo between them is the axis).
  The name is always ink and medium weight; the description is `secondaryInk` regular unless it is the question.
- **Unchanged:** wording of the hint, photo sizes (AX: `cardCompact`), ids (`study.answerHint`, `study.back`,
  `study.photo`), the VoiceOver order (prompt, then answer fields in order), dark and forest (same tokens).
- **Acceptance (QA):** before reveal, `study.answerHint`'s midX equals `study.card`'s midX (± 1 pt) for every
  direction, short and long descriptions; after reveal on a short-description card, `study.back`'s midX equals `study.photo`'s and
  `study.card`'s midX (± 1 pt); `study.front`'s frame is identical before and after reveal; after reveal the hint is gone (not hittable, hidden from VoiceOver) and `study.back`'s
  top equals the hint's former top (± 1 pt); a 3+-line answer description's lines start at one x, inside a block
  centred on `study.photo` (block midX = photo midX ± 1 pt, width ≤ photo width + 48 pt). Screenshots: the existing `study-person-*` set, light + dark, plus a long-description card.

## API / MCP changes
None.

## Accessibility identifiers
New: `study.photo`, `study.answerHint`. Unchanged: `study.front`, `study.back` (now containers
of the prompt / answer fields), `study.card`, `study.reveal`, `study.rate.*`, `study.remaining`, 010/011 ids.

## Out of scope
- Prefetching photos of upcoming cards; zooming the photo.
- Typing the answer; partial credit per answer field (one rating per card).
- Inline edit of photo or multi-field cards (use the deck editor).
