# 017 — Adaptive card text

Status: ready
Owners: ios-engineer (DesignSystem tokens + StudyView), qa-validator
Design: design-lead (reviewed by design-critic). Reference: Vyst `docs/design/reference/02-editor-light.jpg`
(one centered word); Apple Translate / Notes / Dictionary for longer text.

## Goal
Long questions no longer fill the screen at 34 pt, centred and ragged on both sides. The question and the answer
pick a size and an alignment from how much text they hold: a single word stays big and centred, as in Vyst. A
paragraph is smaller and leading-aligned, like Notes. The next card fades in instead of popping.

User feedback: "when the question is long, limit its size … currently it's centred, it doesn't feel smooth …
the question and the answer should have a maximum and minimum font size that adapts to the amount of text."

## Decision
Measure the length of a side: the characters of its shown text fields after trimming whitespace
(`String.count`), with the fields joined by one space. A side is **long** if it has more than
`CardText.longLimit` (60) characters or contains a line break. It is **short** if it has at most
`CardText.shortLimit` (24) characters.

| Question (prompt) | Font token | Style (default size) | Alignment |
|---|---|---|---|
| short (≤ 24) | `.cardFace` (unchanged) | `.largeTitle` medium (34) | centred |
| 25–60 | `.cardFaceMedium` (new) | `.title` medium (28) | centred |
| long (> 60 or a line break) | `.cardFaceSmall` (new, the minimum) | `.title2` medium (22) | leading |

| Answer | Font token | Style | Alignment |
|---|---|---|---|
| short **and** the question isn't long | `.cardAnswer` (new, the maximum) | `.title2` regular (22) | centred |
| otherwise | `.body` (the minimum) | `.body` (17) | leading if the answer is long **or** the question is leading, else centred |

Rules and why:
1. **The question depends only on itself.** Its size and alignment never depend on the answer. The answer
   is hidden before reveal, so a question that changed with it would hint at the answer.
2. **The answer is always below the question.** It is never in a bigger tier, and the colour (`secondaryInk`)
   and weight (regular, not medium) set it apart too. When the question is at its 22 pt minimum, the
   answer drops to 17, so the two never read as equal blocks.
3. **Centre a few lines, align paragraphs to the leading edge.** Centred ragged paragraphs are hard to read.
   Apple centres only short display text and aligns body text to the leading edge (Notes, Translate,
   Dictionary). A short answer under a leading paragraph follows its left edge, so the card never mixes axes
   that way. A short centred question over a long leading answer is fine: it reads like a Dictionary headword
   over its definition.
4. **The thresholds are character counts, not measured lines.** They are deterministic and unit-testable,
   need no second layout pass, and stay the same while the text is being edited. The sizes are system text
   styles, so Dynamic Type still scales them, and the Study cap stays at `.accessibility2`.
5. **Never hide content.** No `lineLimit`, no `minimumScaleFactor`, no truncation. The 22/17 minimums keep a
   ~500-character card on one iPhone screen. Anything longer scrolls in the existing card `ScrollView`, from
   the top. The top bar and the rating row sit outside the scroll view, so they never move.
6. **Leading text uses the screen's 16 pt side padding** (`Theme.Spacing.m`, unchanged). The top-bar circle
   buttons' outer edges sit at 16 pt, so the text lines up with them.
7. **Smooth card changes.** The next card's text fades in (`.transition(.asymmetric(insertion: .opacity,
   removal: .identity))`, `Theme.Motion.standard`, 0.25 s, no slide or scale). The outgoing card leaves at
   once, so a revealed answer never lingers over the new question and the new back never flashes. The new card
   starts scrolled to the top (`.id(card.id)` on the card's scroll content). An opacity fade is acceptable
   under Reduce Motion, so there is no reduced variant to write.
8. **Unchanged:** the stack stays vertically centred when it fits. The answer slot is always laid out, so the
   question never moves on reveal. The halo, the swipe ring, the photo and the answer hint (spec 014d) work
   as before.

Notes cards (014d): the tier and alignment apply to the **first text field** of the prompt (the card face).
Other prompt text fields stay `.body` `secondaryInk` and follow its alignment. A photo always stays centred.
The answer's length is all of its shown text fields together.

Inline edit (010): the field uses the font and alignment of the **saved** text (`card.text(side)`), not the
draft, so the size never changes while the user types. It may change once, when the edit saves.

## DesignSystem API (in `Theme.swift`, implemented by ios-engineer)
```swift
extension Font {
  public static let cardFace = Font.system(.largeTitle, weight: .medium)   // unchanged
  public static let cardFaceMedium = Font.system(.title, weight: .medium)
  public static let cardFaceSmall = Font.system(.title2, weight: .medium)
  public static let cardAnswer = Font.system(.title2)
}
public enum CardText {
  public static let shortLimit = 24
  public static let longLimit = 60
  public static func isLong(_ text: String) -> Bool
  public static func promptFont(_ prompt: String) -> Font
  public static func answerFont(_ answer: String, prompt: String) -> Font
  public static func promptAlignment(_ prompt: String) -> TextAlignment
  public static func answerAlignment(_ answer: String, prompt: String) -> TextAlignment
}
```
In the view, leading text gets `.frame(maxWidth: .infinity, alignment: .leading)` plus
`.multilineTextAlignment(.leading)`. Centred text keeps today's layout. Add the three new fonts and one short
and one long sample to `DesignSystemGalleryContent`.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `promptFont`: 24 chars → `.cardFace`, 25 and 60 → `.cardFaceMedium`, 61 → `.cardFaceSmall`. A 10-char text with a line break → `.cardFaceSmall`. Surrounding whitespace isn't counted. | unit |
| 2 | `answerFont`: a 24-char answer with a short prompt → `.cardAnswer`. A 25-char answer → `.body`. A 7-char answer with a 61-char prompt → `.body`. | unit |
| 3 | `promptAlignment` is `.center` up to 60 chars and `.leading` above 60 or with a line break. `answerAlignment` is `.leading` when the answer is long or the prompt is long, else `.center`. | unit |
| 4 | The fonts for a notes card come from its first prompt text field. The answer's length is all of its shown text fields joined by a space. | unit |
| 5 | Short card (mock "la mer" / "the sea" style): `study.front` and, after reveal, `study.back` are horizontally centred in `study.card` (midX within 1 pt). | UI |
| 6 | Long-question card: the leading edge of `study.front` is the leading edge of `study.card` (within 1 pt), and so is the leading edge of the revealed `study.back`, even when the answer is short. | UI |
| 7 | Short question + long answer: `study.front` is centred and the revealed `study.back` is leading-aligned. | UI |
| 8 | Very long card (> 500 chars): `study.deck`, `study.add`, `study.reveal`, then `study.rate.again` / `study.rate.good` have the same frames as on a short card, and the end of `study.back` can be scrolled into view after reveal. | UI |
| 9 | Long-question card: the frame of `study.front` doesn't move on reveal (regression of 001). | UI |
| 10 | Inline edit on a long-question card (double-tap the revealed front): `study.frontField` has the same leading edge as `study.front` had, and typing past the threshold doesn't change its line height. | UI |
| 11 | After rating, the next card's text fades in over about 0.25 s, with no slide. The previous answer never shows over the new question. | screenshot sequence in QA report (visual) |
| 12 | Accessibility identifiers unchanged. VoiceOver reads the same labels as before. | UI |

Mock data: add `LA_CARTE_API=mock-lengths` (`InMemoryAPIClient`, English sample cards). It is the existing
deck with these four cards first, in this order:
"la mer" / "the sea"; "Which treaty, signed in 1648, ended the Thirty Years' War and is often cited as the origin
of the modern state system?" / "The Peace of Westphalia"; "mitochondria" / "The organelle that produces most of
the cell's energy (ATP) through cellular respiration, often called the powerhouse of the cell."; and one card
of more than 500 characters with a 120-character answer.

## Screens & states
QA captures in light mode, on one simulator: `study-lengths-<short|medium|long|verylong|shortq-longa>-<front|back>`.

Design renders (mock layout via `ImageRenderer`, light, 402 × 874 pt). Top row is before, bottom row is after.
The columns are short / medium / long / very long / short question + long answer / ~470 chars:
- `docs/design/renders/017/sheet-back.png` (revealed)
- `docs/design/renders/017/sheet-front.png` (before reveal)

## TCA shape / API
No state, action or API change. The view changes are in `StudyView` (`prompt`, `answer`, `side`, `field`,
`studying`). Tokens and functions go in `DesignSystem`.

## Accessibility identifiers
Unchanged (`study.front`, `study.back`, `study.frontField`, `study.backField`, `study.card`, …).

## Out of scope
- Deck list rows and the editor (they keep `.body`).
- Measuring rendered lines, or a continuous `minimumScaleFactor`.
- Text-size and VoiceOver test variants (until release).
- The light-mode `secondaryInk` contrast: 2.6:1 on `background`, below WCAG AA 4.5:1 (dark 5.0, forest 5.6).
  This is an existing token used for every answer, so design-lead follows it up separately.
