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
| short **and** the question is centred (1-2 rendered lines) | `.cardAnswer` (new, the maximum) | `.title2` regular (22) | by lines |
| short **and** the question is leading (3+ rendered lines, #16) | `.cardFaceSmall` | `.title2` medium (22) | the question's edge |
| otherwise | `.body` (the minimum) | `.body` (17) | by lines |

**Alignment by rendered lines (amended 2026-11-22, user feedback).** Sizes stay on character counts; alignment
follows the lines the text actually wraps to at the current width and text size:
- A side of **1 or 2 lines** is centred, line by line.
- A side of **3 or more lines** is leading-aligned.
- The question depends only on itself. The answer follows the question's axis when the question is leading
  (3+ lines): it is then leading on the question's edge, whatever its length; under a centred question it follows its
  own line count (amended 2026-11-28 per user, twice: see "One axis per card + weight transfer", #16).

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
- **D (default, user's pick of 2026-11-22)**: the question is placed as in B. The answer's alignment is measured in
  the full column (1-2 lines centred, 3+ leading, leading under a leading question). A **centred** answer always
  keeps the full column, centred, even when wider than the question (amended 2026-11-22 per user: "when the answer
  is not justified left, it is not constrained by the question width"). A **leading** answer under a **wide**
  question (its widest line as drawn fills at least 85 % of the column, whether or not it wraps) takes that line's
  width as its column, starting at the question's left edge, never wider than it; a leading answer has 3+ lines in
  the full column, so it has 3+ in that narrower one too, and the measure never depends on the column it picks.
  Any other question (widest line under 85 %, even wrapped) leaves the answer as in A (amended 2026-11-22 per user:
  trigger on width only; "Who composed The Magic Flute?" wraps to 2 lines whose widest fills ~68 % of the column, and
  "the title … doesn't take enough width to define the width for the answer"). Why 85 %: a line that fills that
  much reads as a full-width block, and an answer wider than it would overhang it by under ~28 pt a side (half of
  15 % of a 370 pt column), which looks like a misalignment; under 85 % the question is display text with wide
  margins (big font, long words), and squeezing the answer under it would wrap it for no reason. The whole answer slot of a leading answer takes that width, so a person card's hint and
  an answer photo stay inside it too. A wrapped line's measured width keeps the space it breaks at, so the answer's ink can
  pass the question's by up to ~5 pt on the right.
In all four the question's frame never depends on the answer, and the inline edit field keeps the shown text's
width (B, C, D's leading question, D's leading answer's column) or the column (A).

Rules and why:
1. **The question depends only on itself.** Its size and alignment never depend on the answer. The answer
   is hidden before reveal, so a question that changed with it would hint at the answer.
2. **The answer is always below the question.** It is never in a bigger tier, and the colour (`secondaryInk`)
   and weight (regular, not medium) set it apart too. *(Under a leading question, #16: the answer takes `ink` and the question
   recedes to `recededInk` on reveal.)* When the question is at its 22 pt minimum, the
   answer drops to 17, so the two never read as equal blocks.
3. **Centre a few lines, align paragraphs to the leading edge.** Centred ragged paragraphs are hard to read.
   Apple centres only short display text and aligns body text to the leading edge (Notes, Translate,
   Dictionary). "A few" is two rendered lines (see the amendment above). Each side picks its own axis: a short
   centred answer under a leading paragraph question reads as the punchline under it (user, blind A/B 2026-11-28),
   and a short centred question over a long leading answer reads like a Dictionary headword over its definition.
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
   *Exception (per user 2026-11-22):* a person card with a text prompt moves its question on reveal so the
   photo, name and description end centred as one group (spec 014d, "Text prompt: the question moves on reveal").
   *Exception (per user 2026-11-25):* a basic card whose question would sit visibly high starts centred and lifts on
   reveal (see "Reveal lift" below).

Notes cards (014d): the tier and alignment apply to the **first text field** of the prompt (the card face).
Other prompt text fields stay `.body` `secondaryInk` and follow its alignment. A photo always stays centred.
The answer's length is all of its shown text fields together.

Inline edit (010): the field uses the font and alignment of the **saved** text (`card.text(side)`), not the
draft, so the size never changes while the user types. It may change once, when the edit saves.

## Reveal lift (design note, per user 2026-11-25)
User: "if it's higher by more than a margin, like if it's obviously not in the center of the screen, we should just
have it in the center of the screen initially and then move it, just like in the people card."

**Measured** (real `StudyView` renders, iPhone 17 Pro, light, default text size): how far the question's centre sits
above the card's centre before reveal today. The card's centre is 7 pt below the screen's (y 444 vs 437 pt).

| Question \ answer | 1 line | 2 lines | 4 lines | 8 lines |
|---|---|---|---|---|
| 1 line ("la mer") | 24 pt | 33 pt | 59 pt | 111 pt |
| 2 lines | 24 pt | 33 pt | 72 pt | 124 pt |
| 5 lines | 20 pt | 33 pt | 72 pt | 124 pt |

**Rule** (basic cards; the person card keeps 014d):
- `lift = max(0, (cardHeight − questionHeight) / 2 − max(0, (cardHeight − pairHeight) / 2))`: the distance from the
  question centred in the card to its final place (the pair centred, or the top when the pair overflows).
  `questionHeight` is the prompt view's height, `pairHeight` the question + `Spacing.m` + answer stack's (the answer
  is laid out while hidden, as today), `cardHeight` the existing `cardHeight` state.
- **Threshold `Theme.Spacing.xl` (40 pt):** `lift ≤ 40` → today's behaviour, nothing moves. `lift > 40` → before
  reveal the stack is drawn `.offset(y: lift)` (question centred); on reveal the offset goes to 0. Why 40: the
  optical centre of a tall frame sits ~5 % above its geometric centre (~33 pt on this 650 pt card), so a question up
  to ~40 pt high still reads as centred. That keeps 1- and 2-line answers (20–33 pt) still, the common case, and
  moves 3+ line answers (≥ ~46 pt), where the gap below the question is visible. A token, not a new number.
- **Motion:** the same tokens as the person card. The offset animates with `Theme.Motion.reveal`
  (`.smooth(duration: 0.35)`, critically damped, no overshoot), in one transaction from every reveal path
  (`.transaction(value: store.isRevealed)`, as the person card does). The answer keeps its own opacity fade
  (`Theme.Motion.standard`, 0.25 s) and, being in the offset stack, rises with the question. Only the reveal
  animates the offset: a new card's measurements set it without animation (the card is fading in from 0 opacity).
- **Reduce Motion:** no lift: the question starts in its final place (today's behaviour) and only the answer fades.
  Why: nothing slides and nothing is drawn twice; a cross-fade of the same question between two places reads as a
  double image. The person card cross-fades because its prompt also changes style; a basic card's doesn't.
- **Scrolling:** offset is visual only, so the scroll view's content size and the answer's place don't change. When
  the pair overflows the card, the final place is the top (rule 5) and the question starts centred, then lifts to
  the top on reveal. When the question alone overflows the card, `lift` is 0 (it starts at the top, as today). The
  card still starts scrolled to the top on a new card; no scroll on reveal.
- **Editing / unchanged:** the lift applies only before reveal, so inline edit (010, revealed) is unchanged. No
  change to `answerAlignment` (pending user decision), widths or fonts.

**Blind A/B** (design-critic, 2026-11-25, unlabelled, random order per sheet): lift 8, 8, 8 (mean 8.0) vs today
7, 5, 5 (mean 5.7); lift won every sheet. Critic's notes, all covered above: critically damped spring, Reduce Motion
in the final place, a very long pair falls back to the scroll layout. Sheets (today on top, lift below; before
reveal, frames at 50/100/150/250 ms, after): `docs/design/renders/017/reveal-lift/q2a4.png`, `q1a8.png`, `q5a8.png`;
blind copies in `reveal-lift/blind/` (key: sheet-1 A = lift, sheet-2 and sheet-3 B = lift).

**ios-engineer** (`StudyView.studying`, basic branch only): measure the prompt's and the stack's heights
(`onGeometryChange`), compute `lift` as above, apply `.offset(y: store.isRevealed || reduceMotion ? 0 : lift)` to
the basic `VStack`, and extend the reveal `.transaction` to set `Theme.Motion.reveal` for a basic card when
`lift > Theme.Spacing.xl`. Put `lift(card:question:pair:)` and the threshold in a pure function with unit tests
(39/40/41 pt, overflowing pair, overflowing question). Update `ScreenColorTests.questionStaysPut` for #13/#14.

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
| 6 | Question of 3+ rendered lines (layout D): `study.front` is a block centred in `study.card` (midX within 1 pt), its lines leading; when its widest line fills ≥ 85 % of the column, the revealed `study.back`, even a short one, starts at the question's left edge (within 1 pt) and ends within its right edge (+6 pt); otherwise it starts at the column's edge, as in 7. A 2-line question is centred and a 1-line answer under it is centred on it, in the full column, wider than the question if it needs (amended 2026-11-22 per user). | UI |
| 7 | Narrow question (widest line under 85 % of the column, one line or wrapped, e.g. "Who composed The Magic Flute?") + answer of 3+ lines: `study.front` is centred and the revealed `study.back` is leading at the column's edge (`study.card` minX within 1 pt), wider than the question. Wide question (widest line ≥ 85 %, wrapped or not) + answer of 3+ lines: the answer starts at the question's left edge and stays within its width (+6 pt). An answer of 1–2 lines (in the full column) is centred in the full column, not held to the question's width (amended 2026-11-22 per user, twice: a centred answer keeps the column; trigger on width only). | UI |
| 8 | Very long card (> 500 chars): `study.deck`, `study.add`, `study.reveal`, then `study.rate.again` / `study.rate.good` have the same frames as on a short card, and the end of `study.back` can be scrolled into view after reveal. | UI |
| 9 | Long-question card: the frame of `study.front` doesn't move on reveal (regression of 001). | UI |
| 10 | Inline edit on a long-question card (double-tap the revealed front): `study.frontField` has the same leading edge and width (within 1 pt) as `study.front` had, and typing past the threshold doesn't change its line height. Editing a leading answer under a wide question: `study.backField` keeps `study.back`'s left edge and width (the question's column); a centred answer's field spans the column. | UI |
| 11 | After rating, the next card's text fades in over about 0.25 s, with no slide. The previous answer never shows over the new question. | screenshot sequence in QA report (visual) |
| 12 | Accessibility identifiers unchanged. VoiceOver reads the same labels as before. | UI |
| 13 | In layouts A to D, for 1-, 2-, 3- and 5-line questions and single lines filling 74, 89, 92 and 98 % of the column, with 1-, 2- and 4-line answers, revealing doesn't change a pixel of the question, and the question's columns are the same whatever the answer. In D, under a wide question (widest line ≥ 85 %) a leading answer's ink stays within the question's (3 pt left, 6 pt right for the break space), under any other (the 1-line, the 68 % 2-line and the 74 % questions) it starts at the column's edge, wider than the question, and a centred one shares its centre (`ScreenColorTests.questionStaysPut`); a 1-line answer wider than a 2-line question stays on one line (`ScreenColorTests.centredAnswerIgnoresTheQuestionWidth`; amended 2026-11-22 per user). On device (layout D, iPhone 17 Pro): `study.front`'s frame is identical before and after reveal for wide (≥ 85 %) and narrow (under 85 %, one line or wrapped) questions with 1- and 3+-line answers, and the question's pixels don't move (`screen-sample.py compare`). | render + UI |
| 14 | *Amends #9 and #13 (2026-11-25).* "Revealing doesn't change a pixel of the question" holds when `lift ≤ 40 pt` (1- and 2-line answers). When `lift > 40` (e.g. 4-line answers), the question is vertically centred in `study.card` before reveal (± 1 pt) and after reveal its pixels are identical to today's revealed render; its horizontal place and columns never change. Reduce Motion: no lift (as #13). | render + UI |
| 15 | *Amends #6, #7 and #13 (2026-11-28, "Answer alignment").* Basic card, revealed, layout D, light **and** dark: the answer's alignment depends only on its own rendered lines. (a) A question of 3+ lines (leading) with a 1-line answer (mock-lengths "Which treaty, signed in 1648…" / "The Peace of Westphalia"): `study.back` is centred in `study.card` (midX within 1 pt) and does **not** start at the question's left edge. (b) The same question with a 2-line answer: `study.back` centred (midX within 1 pt), its two lines each centred. (c) The same question with a 3+-line answer: `study.back` leading, starting at `study.front`'s left edge (within 1 pt), within its width (+6 pt), as before. (d) A 1-line centred question with a 3+-line answer: `study.back` leading at the column's edge, as before. (e) The question's frame and pixels on reveal are unaffected (#13, #14). (f) Person cards unchanged (014d). Unit: `answerAlignment`'s rule is `.center` for a 1-2-line answer under a 3+-line question, `.leading` for 3+ lines under any question (`StudyTextLayoutTests`). | unit + render + UI |
| 16 | *Amends #2, #6, #7, #10, #13 and #15 (2026-11-28, "One axis per card + weight transfer").* Layout D, light **and** dark (forest by token values). (a) **Leading question, 1-line answer** (Westphalia: "Which treaty, signed in 1648…" / "The Peace of Westphalia"; and Git): `study.front` starts at `study.card` minX + 16 pt (± 1), lines leading; revealed `study.back` starts at `study.front`'s minX (± 1), font `.cardFaceSmall` (`.title2` medium), colour `ink` (#1C1C1C / #F2F2F0). Before reveal `study.front` is `ink`; after reveal `recededInk` (#6F6F6D / #8A8A88), measured ≥ 4.5:1 on `background` (`screen-sample.py contrast`). (b) **Leading question, 2-line answer** ("Which English idiom…" / "To feel down, to have the blues…"): `study.back` leading at `study.front`'s minX (± 1), both lines starting there, `.body`, `ink`; question `recededInk` after reveal. (c) **Leading question, 3+-line answer** (the 017 long Q / Westphalia paragraph): as (b), and `study.back` may be wider than the question, never wider than the column. (d) **Centred question, unchanged**: "la mer" / "the sea" both centred (midX ± 1), question `ink` before and after reveal, answer `.cardAnswer` `secondaryInk`; "mitochondria" + 3+-line answer: question centred `ink`, answer leading at the column edge, `.body` `secondaryInk`; a 2-line centred question with a 1-2-line answer: answer centred. (e) **Motion**: on reveal of a leading-question card, `study.front`'s colour crossfades `ink` → `recededInk` over 0.25 s ease-in-out (`Theme.Motion.standard`; a frame at ~125 ms is between the two); with **Reduce Motion** the same crossfade runs and there is no lift (#14). A new card's question shows in `ink` from its first frame. (f) **Position**: revealing doesn't move the question: `study.front`'s frame is identical before and after, and its ink mask (`screen-sample.py bbox`/`bands`) is unchanged; only its colour changes (replaces #13's "not a pixel" for leading questions). (g) **Edit**: double-tapping a revealed leading question gives `study.frontField` starting at 16 pt, spanning the column, in `recededInk`. (h) **Person cards unchanged** (014d): alignment and colours as before. (i) Unit: `CardText.answerFont(_:questionLeads:)` — a 7- or 24-char answer under a leading question → `.cardFaceSmall`; a 25-char answer → `.body`; a 24-char answer under a centred question → `.cardAnswer`. `answerAlignment(question:answer:)` → `.leading` for a 1-, 2- and 3+-line answer under a leading question; `.center` for 1-2 lines and `.leading` for 3+ under a centred one (`StudyTextLayoutTests`). | unit + render + UI |

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

## Answer alignment (design note, per user 2026-11-28; superseded for leading questions by #16)
User, after a blind A/B of real `StudyView` renders (light + dark, five revealed basic cards): "I prefer A.png
answered centered even if question was left". A was this rule; B was the rule above it (answer forced leading under a
leading question).

**Rule** (basic cards; person cards keep 014d, always centred):
- `answerAlignment = backMeasure.isMultiline ? .leading : .center`. The question's alignment no longer enters it.
- "Multiline" is the existing probe, unchanged: the answer's saved text laid out in the card's column at the
  current Dynamic Type size, full height vs. the same text cut to `lineLimit(2)`; taller than the two-line copy by
  more than 1 pt = 3+ lines = leading. So **1-2 rendered lines: centred; 3+: leading**, whatever the question.
- The question's rule is unchanged (`frontMeasure.isMultiline ? .leading : .center`).
- Everything else follows from the existing layout D rules, unchanged: a centred answer always keeps the full
  column, centred on `study.card` (never held to the question's width); a leading answer under a wide question
  (widest line ≥ 85 % of the column) takes the question's width and left edge; under a narrow one, the column's
  edge. The centred answer's edit field spans the column (#10). The reveal lift (#14) and the spacing between the
  two sides (`Theme.Spacing.m`) are unchanged.
- Code: one line in `StudyView.answerAlignment` (drop `promptAlignment == .leading ||`) and its doc comment. No new
  token, no state.

Seen in A (light and dark): long question (leading) + "Mitochondria", "The Peace of Westphalia", and a 2-line "To
feel down, to have the blues, to be in low spirits for a while": answer centred. Long question + 5-line answer:
both leading, answer at the question's left edge. "Speed of light" (centred) + 4-line answer: answer leading at the
column's edge.

*Dropped:* the later 3-option balance experiment (branch `design-lead/answer-balance-exp`: separated spacing,
shared edge, centred axis with an 85 % measure and a bigger answer font) is superseded by this decision and won't
ship.

## One axis per card + weight transfer (design note, per user 2026-11-28)
User, after a round on one of their own cards (long question, one-word answer), picked **P2 "weight transfer"** and added: "I don't
understand why for the one you named long question, two line answer, the answer is centered. I think we got to be
coherent. And like if we go back to aligning left the answers, like we should also do it for the two lines answers."
This **replaces** "Answer alignment" above (and #15 (a), (b)) for the leading-question case. Criterion: #16.

**Rule** (basic and notes cards; person cards keep 014d):
1. **One axis per card.** A question of 3+ rendered lines (leading, the existing `frontMeasure` probe) puts its answer
   on the **same left edge**, leading, whatever the answer's length (1, 2 or 3+ lines). A question of 1-2 lines
   (centred) keeps today's answer rule: 1-2 lines centred, 3+ leading.
   `answerAlignment = promptAlignment == .leading ? .leading : (backMeasure.isMultiline ? .leading : .center)`.
2. **One fixed edge for leading text.** A leading question is laid out in the full column (layout A's placement:
   lines start at the 16 pt side padding, `Theme.Spacing.m`, ragged right), not as a block centred at its own width,
   and its answer uses the same full column. Measured (real renders, iPhone 17 Pro, light): with the centred block,
   the left edge of a leading question drifts 16-31 pt from card to card (the user's card 16.3, Git 21, Westphalia 28,
   long Q/long A 31, "Photosynthesis…" 18.7); fixed, it is 16.3-17 on every card, the same edge as the top bar's
   deck button. *User-visible effect:* a paragraph question moves up to ~15 pt left (only when its widest line is
   short of the column) and stays there before and after reveal; its right margin is ragged instead of mirrored; a
   long answer under it spans the column instead of the question's width, so it can take one line less. The 85 %
   rule (layout D) now applies only under a **centred** (2-line, wide) question, unchanged.
3. **Weight transfer, on every leading-question card.** Under a leading question the answer is drawn in `Theme.ink`;
   on reveal the question crossfades from `ink` to `Theme.recededInk`. Under a centred question nothing changes:
   question `ink`, answer `secondaryInk`, no colour change on reveal.
   *Why every leading-question card, not only long Q / short A:* one trigger (the line probe that already picks the
   axis) drives both effects, so there is no third condition on the answer's length. A paragraph question is the
   content the user reads before reveal; after reveal the eye must land on the answer whatever its length (visual
   weight comes from value as much as size: research note principle 1). Orbit / Quantum Country demotes the
   question on every reveal, not only for short answers (principle 6). Limiting it to short answers would leave a long
   grey answer under a long ink question, the inverted hierarchy the blind critic called out ("the thing just
   revealed is the faintest text on screen"). *Why not centred questions:* a 1-2-line question is display text, a
   headword; size (34/28 vs 22/17) already sets the hierarchy (Dictionary pattern), and greying a one-word question
   reads as disabled. That's the user's rule ("centred: today's behaviour").
4. **Font.** Sizes stay on character counts (rule 4). One change in `CardText.answerFont`: a short answer
   (≤ 24 chars) under a **leading** question (3+ rendered lines) is `.cardFaceSmall` (`.title2` medium, the
   question's tier). The bump follows the rendered axis, not the question's character count (decided in
   implementation 2026-11-28: `answerFont(_:questionLeads:)`), so a short answer under a centred question stays
   `.cardAnswer` however long the question, and one under a 25-60-char question that wraps to 3+ lines gets
   `.cardFaceSmall`. A one-word answer in ink at 17 pt reads as a caption under a 22 pt paragraph (P2 as picked).
   Rule 2 still holds: `.cardFaceSmall` is every question's minimum tier, so the answer is never bigger. Other
   answers unchanged (`.body`).
5. **`recededInk`** (new DesignSystem token, `Theme.swift`): light `#6F6F6D`, dark `#8A8A88`, forest `#83938A`.
   Measured on the renders with `screen-sample.py contrast`: light 4.8:1, dark 5.03:1 on `background` (forest
   5.57:1 by the token values). AA for text in every theme; `secondaryInk` light (2.6:1) is not used for this.
6. **Motion.** The question's colour change animates with `Theme.Motion.standard` (0.25 s ease-in-out), scoped to the
   prompt's foreground style and driven by `store.isRevealed` (the `.animation(_:body:)` form, as the answer's
   opacity). It runs alongside the reveal lift (#14) when there is one. **Reduce Motion: the crossfade stays** (a
   colour fade moves nothing, like the answer's opacity fade); only the lift is dropped (#14). A new card's question
   appears in `ink` with the card's fade-in, never fading from grey.
7. **Edit (010).** The edit field keeps the side's colour (a revealed leading question edits in `recededInk`), and a
   leading question's field spans the column, starting at 16 pt.

**Renders** (real `StudyView`, iPhone 17 Pro, rows: today revealed / new before reveal / new revealed; columns Git,
Westphalia, short Q/A, long Q + 2-line A, long Q / long A, short Q / long A), built from a local exploration patch
(branch `design-lead/coherent-axis-exp`, not merged):
`<scratch>/renders/design-lead-coherent/sheet-017-16-light.png` and `…-dark.png` (local, not committed).

**Blind A/B** (fresh design-critic, 2026-11-28, unlabelled A/B sheets, six cards, light + dark): new 6/10 vs today
4/10; new won ("constant left margin", "the revealed answer is what you read"). Key: A = new. Critic's other points,
settled: it asked to transfer the weight on centred cards too (declined: the user's rule keeps them, see 3); it read
long answers as ~13 pt (they are `.body` 17 pt, a sheet-scale misreading); question-to-answer spacing stays
`Theme.Spacing.m` on every card.

**ios-engineer** (`StudyView`, `CardText`):
- `answerAlignment` as rule 1; put the rule in a pure static function and unit-test it (`StudyTextLayoutTests`).
- Leading question: `prompt(card).placed(promptAlignment, asBlock: false)`; `answerWidth` is nil when
  `promptAlignment == .leading`; `editWidth(.front)` nil for a leading question.
- `prompt` colour `promptAlignment == .leading && store.isRevealed ? Theme.recededInk : Theme.ink`, animated as rule 6;
  `answer` colour `promptAlignment == .leading ? Theme.ink : Theme.secondaryInk`. Notes cards: other prompt text
  fields stay `.body` `secondaryInk`.
- `CardText.answerFont` as rule 4; update its unit tests (#2) and `ScreenColorTests.questionStaysPut` (#13 now
  compares the question's shape, not its colour, across reveal on leading-question cards).

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
