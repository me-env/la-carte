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
| short (≤ 24) | `.cardFace` (unchanged) | `.largeTitle` medium (34) | by lines (below) |
| 25–60 | `.cardFaceMedium` (new) | `.title` medium (28) | by lines |
| long (> 60 or a line break) | `.cardFaceSmall` (new, the minimum) | `.title2` medium (22) | by lines |

| Answer | Font token | Style | Alignment |
|---|---|---|---|
| short **and** the question isn't long | `.cardAnswer` (new, the maximum) | `.title2` regular (22) | by lines |
| otherwise | `.body` (the minimum) | `.body` (17) | by lines |

**Alignment by rendered lines (amended 2026-11-22, user feedback).** Sizes stay on character counts; alignment
follows the lines the text actually wraps to at the current width and text size:
- A side of **1 or 2 lines** is centred, line by line.
- A side of **3 or more lines** is leading-aligned.
- The question depends only on itself. The answer is leading when the question is leading (so the two never mix
  axes that way), otherwise by its own line count.

How it's measured: in the card's column, a hidden copy of each side's **saved** text is laid out cut to two lines
(`lineLimit(2)`), with the full text over it. If the full text is taller, the side has 3+ lines. The probe is
laid out with the card, so it follows the width and Dynamic Type, has no thresholds or line-height constants, and
never follows a draft while editing. A new card's first layout pass uses the previous card's measure; the next
pass corrects it, under the card's 0.25 s fade-in from 0, so nothing visibly jumps. Notes cards (014d) are
measured like the sizes: the question on its first text field, the answer on its text fields joined by a space.

Leading text has four candidate placements, behind one switch (`StudyView.textLayout`) until the user picks one
from the A/B/C/D render sheet (`StudyRenders/layouts`):
- **A**: the full-width column, lines starting at the 16 pt side padding (`Theme.Spacing.m`); a leading
  question and its answer share that left edge.
- **B**: each side is a block as wide as its widest line, centred in the column; lines left-aligned in the block.
- **C**: B, but when the question and a leading answer differ in width by less than 15 % (an "almost aligned"
  pair reads as a mistake) and the answer still fits, the answer's block moves to the question's left edge.
  Clearly different widths stay centred on their own, which reads as intended.
- **D (default, user's pick of 2026-11-22)**: the question is placed as in B. When it is **wide** (it wraps, or one
  line fills at least 85 % of the column), its widest line becomes the answer's column, centred: the answer wraps
  inside it and is never wider than the question. Its alignment comes from its lines measured at that width (1-2
  centred, 3+ leading, leading under a leading question), and a leading answer starts at the question's left edge.
  A short question (one line under 85 %) leaves the answer as in A. Why 85 %: a line that fills that much reads as
  a full-width block, and an answer wider than it would overhang it by under ~28 pt a side (half of 15 % of a
  370 pt column), which looks like a misalignment; under 85 % the question is short display text with wide
  margins, and squeezing the answer under it would wrap it for no reason. The question is measured with a second
  cut (one line) in the same probe. The whole answer slot takes that width, so a person card's hint and an answer
  photo stay inside it too. A wrapped line's measured width keeps the space it breaks at, so the answer's ink can
  pass the question's by up to ~5 pt on the right.
In all four the question's frame never depends on the answer, and the inline edit field keeps the shown text's
width (B, C, D's leading question, D's answer column) or the column (A).

Rules and why:
1. **The question depends only on itself.** Its size and alignment never depend on the answer. The answer
   is hidden before reveal, so a question that changed with it would hint at the answer.
2. **The answer is always below the question.** It is never in a bigger tier, and the colour (`secondaryInk`)
   and weight (regular, not medium) set it apart too. When the question is at its 22 pt minimum, the
   answer drops to 17, so the two never read as equal blocks.
3. **Centre a few lines, align paragraphs to the leading edge.** Centred ragged paragraphs are hard to read.
   Apple centres only short display text and aligns body text to the leading edge (Notes, Translate,
   Dictionary). "A few" is two rendered lines (see the amendment above). A short answer under a leading
   paragraph follows its left edge, so the card never mixes axes that way. A short centred question over a long leading answer is fine: it reads like a Dictionary headword
   over its definition.
4. **The size thresholds are character counts, not measured lines.** They are deterministic and
   unit-testable, and stay the same while the text is being edited (alignment uses measured lines: see above).
   The sizes are system text styles, so Dynamic Type still scales them, and the Study cap stays at
   `.accessibility2`.
5. **Never hide content.** No `lineLimit`, no `minimumScaleFactor`, no truncation. The 22/17 minimums keep a
   ~500-character card on one iPhone screen. Anything longer scrolls in the existing card `ScrollView`, from
   the top. The top bar and the rating row sit outside the scroll view, so they never move.
6. **Leading text uses the screen's 16 pt side padding** (`Theme.Spacing.m`, unchanged) in layout A. The
   top-bar circle buttons' outer edges sit at 16 pt, so the text lines up with them. B and C centre the block.
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
}
```
Alignment is not in `CardText` (it needs the layout): StudyView measures the lines (see the amendment). Add the three new fonts and one short
and one long sample to `DesignSystemGalleryContent`.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `promptFont`: 24 chars → `.cardFace`, 25 and 60 → `.cardFaceMedium`, 61 → `.cardFaceSmall`. A 10-char text with a line break → `.cardFaceSmall`. Surrounding whitespace isn't counted. | unit |
| 2 | `answerFont`: a 24-char answer with a short prompt → `.cardAnswer`. A 25-char answer → `.body`. A 7-char answer with a 61-char prompt → `.body`. | unit |
| 3 | A side is multi-line (leading) when its full height exceeds its two-line height; layout C moves the answer only when the widths differ by < 15 % and the answer still fits the column (`StudyTextLayoutTests`). | unit |
| 4 | The fonts for a notes card come from its first prompt text field. The answer's length is all of its shown text fields joined by a space. | unit |
| 5 | Short card (mock "la mer" / "the sea" style): `study.front` and, after reveal, `study.back` are horizontally centred in `study.card` (midX within 1 pt). | UI |
| 6 | Question of 3+ rendered lines (layout A): the leading edge of `study.front` is the leading edge of `study.card` (within 1 pt), and so is the leading edge of the revealed `study.back`, even when the answer is short. A 2-line question is centred. | UI |
| 7 | Short question + answer of 3+ lines: `study.front` is centred and the revealed `study.back` is leading-aligned; an answer of 2 lines is centred. | UI |
| 8 | Very long card (> 500 chars): `study.deck`, `study.add`, `study.reveal`, then `study.rate.again` / `study.rate.good` have the same frames as on a short card, and the end of `study.back` can be scrolled into view after reveal. | UI |
| 9 | Long-question card: the frame of `study.front` doesn't move on reveal (regression of 001). | UI |
| 10 | Inline edit on a long-question card (double-tap the revealed front): `study.frontField` has the same leading edge as `study.front` had, and typing past the threshold doesn't change its line height. | UI |
| 11 | After rating, the next card's text fades in over about 0.25 s, with no slide. The previous answer never shows over the new question. | screenshot sequence in QA report (visual) |
| 12 | Accessibility identifiers unchanged. VoiceOver reads the same labels as before. | UI |
| 13 | In layouts A to D, for 1-, 2-, 3- and 5-line questions and single lines filling 74, 89, 92 and 98 % of the column, with 1-, 2- and 4-line answers, revealing doesn't change a pixel of the question, and the question's columns are the same whatever the answer. In D, under a wide question the answer's ink stays within the question's (3 pt left, 6 pt right for the break space) (`ScreenColorTests.questionStaysPut`). | render |

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
