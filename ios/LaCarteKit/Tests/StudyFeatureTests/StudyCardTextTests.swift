@testable import APIClient
import DesignSystem
import Foundation
import SwiftUI
import Testing

@testable import StudyFeature

/// Spec 017, notes cards: the question is measured from its first text field, the answer from all its text fields.
struct StudyCardTextTests {
  let person = [Note].fixtures[0]

  func card(prompt: [String], answer: [String], fields: [String: String] = [:]) -> Card {
    var note = person
    note.fields.merge(fields) { $1 }
    return Card(note: note, card: Note.Card(id: UUID(), prompt: prompt, answer: answer, due: .now))
  }

  @Test func theQuestionIsMeasuredFromItsFirstTextFieldOnly() {
    let longDescription = String(repeating: "a", count: 61)
    let nameFirst = card(prompt: ["photo", "name", "description"], answer: [], fields: ["description": longDescription])
    #expect(nameFirst.promptText == "Ada Example")
    #expect(nameFirst.promptFont == .cardFace)

    let descriptionFirst = card(prompt: ["description", "name"], answer: [], fields: ["description": longDescription])
    #expect(descriptionFirst.promptFont == .cardFaceSmall)
  }

  @Test func anEmptyFirstFieldIsSkipped() {
    let card = card(prompt: ["description", "name"], answer: [], fields: ["description": ""])
    #expect(card.promptText == "Ada Example")
  }

  @Test func theAnswerIsAllItsTextFieldsJoinedByASpace() {
    let card = card(prompt: ["photo"], answer: ["photo", "name", "description"], fields: ["name": " Ada Example "])
    #expect(card.answerText == "Ada Example runs the bakery")
  }

  /// Spec 014d: every direction reveals the same composition, photo, name, description; an empty field is left out.
  @Test func aPersonCardRevealsPhotoNameDescriptionWhateverWasAsked() {
    for (prompt, answer) in [(["photo"], ["name", "description"]), (["name"], ["photo", "description"]),
                             (["description"], ["photo", "name"])] {
      #expect(card(prompt: prompt, answer: answer).personRows == ["photo", "name", "description"])
    }
    #expect(card(prompt: ["name"], answer: ["photo", "description"], fields: ["description": ""]).personRows
      == ["photo", "name"])
  }

  @Test func onlyAPersonCardsTextPromptMovesOnReveal() {
    #expect(card(prompt: ["name"], answer: ["photo", "description"]).isPersonWithTextPrompt)
    #expect(card(prompt: ["description"], answer: ["photo", "name"]).isPersonWithTextPrompt)
    #expect(!card(prompt: ["photo"], answer: ["name", "description"]).isPersonWithTextPrompt)
    var basic = card(prompt: ["front"], answer: ["back"], fields: ["front": "la mer", "back": "the sea"])
    basic.type = .basic
    #expect(!basic.isPersonWithTextPrompt)
  }
}

/// Spec 014d: a person card's rows sit `m` under the photo and `xs` apart; the description's caption block is the
/// photo's width plus `l` on each side.
@MainActor
struct StudyPersonLayoutTests {
  @Test func rowsSitMUnderThePhotoAndXsApart() {
    let rows = ["photo", "name", "description"]
    #expect(StudyView.gap(before: "photo", in: rows) == 0)
    #expect(StudyView.gap(before: "name", in: rows) == Theme.Spacing.m)
    #expect(StudyView.gap(before: "description", in: rows) == Theme.Spacing.s)
    #expect(StudyView.gap(before: "description", in: ["description"]) == 0)  // a text prompt before reveal
    #expect(StudyView.gap(before: "description", in: ["photo", "description"]) == Theme.Spacing.m)
  }

  @Test func theCaptionBlockIsThePhotoWidthPlusLOnEachSide() {
    #expect(StudyView.captionWidth(isAccessibilitySize: false) == 288)
    #expect(StudyView.captionWidth(isAccessibilitySize: true) == Theme.Photo.cardCompact + 2 * Theme.Spacing.l)
  }
}

/// Spec 017 alignment: 3+ rendered lines are leading; layout C snaps only nearly equal blocks that still fit; layout D
/// keeps a leading answer inside a question whose widest drawn line fills 85 % of the column.
@MainActor
struct StudyTextLayoutTests {
  @Test func threeRenderedLinesAreMultiline() {
    #expect(!StudyView.TextMeasure(width: 100, height: 26, twoLines: 26).isMultiline)
    #expect(!StudyView.TextMeasure(width: 100, height: 52, twoLines: 52).isMultiline)
    #expect(StudyView.TextMeasure(width: 100, height: 78, twoLines: 52).isMultiline)
  }

  @Test func aSideAlignsOnItsOwnLinesOnly() {
    let oneLine = StudyView.TextMeasure(width: 200, height: 26, twoLines: 26)
    let twoLines = StudyView.TextMeasure(width: 340, height: 52, twoLines: 52)
    let threeLines = StudyView.TextMeasure(width: 340, height: 78, twoLines: 52)
    #expect(StudyView.alignment(of: oneLine) == .center)
    #expect(StudyView.alignment(of: twoLines) == .center)
    #expect(StudyView.alignment(of: threeLines) == .leading)
  }

  @Test func oneAxisPerCard() {
    let oneLine = StudyView.TextMeasure(width: 200, height: 26, twoLines: 26)
    let twoLines = StudyView.TextMeasure(width: 340, height: 52, twoLines: 52)
    let threeLines = StudyView.TextMeasure(width: 340, height: 78, twoLines: 52)
    // Under a leading question, every answer shares its edge (#16).
    #expect(StudyView.answerAlignment(question: .leading, answer: oneLine) == .leading)
    #expect(StudyView.answerAlignment(question: .leading, answer: twoLines) == .leading)
    #expect(StudyView.answerAlignment(question: .leading, answer: threeLines) == .leading)
    // Under a centred one, the answer aligns on its own lines.
    #expect(StudyView.answerAlignment(question: .center, answer: oneLine) == .center)
    #expect(StudyView.answerAlignment(question: .center, answer: twoLines) == .center)
    #expect(StudyView.answerAlignment(question: .center, answer: threeLines) == .leading)
  }

  /// #16: under a leading question the answer takes the ink (the question recedes); otherwise it stays secondary.
  @Test func theAnswerTakesTheInkUnderALeadingQuestion() {
    let environment = EnvironmentValues()
    let ink = Theme.ink.resolve(in: environment)
    #expect(StudyView.answerColor(question: .leading).resolve(in: environment) == ink)
    #expect(StudyView.answerColor(question: .center).resolve(in: environment) == Theme.secondaryInk.resolve(in: environment))
  }

  @Test func layoutCSnapsNearlyEqualBlocksThatStillFit() {
    #expect(StudyView.snap(answer: 300, toQuestion: 280, column: 370) == 10)
    #expect(StudyView.snap(answer: 280, toQuestion: 300, column: 370) == -10)
    #expect(StudyView.snap(answer: 200, toQuestion: 300, column: 370) == 0)  // clearly different: left centred
    #expect(StudyView.snap(answer: 360, toQuestion: 340, column: 370) == 0)  // would cross the right margin
  }

  @Test func layoutDKeepsALeadingAnswerInsideAWideWrappingQuestion() {
    let paragraph = StudyView.TextMeasure(width: 360, drawnWidth: 354, height: 112, twoLines: 56, column: 370)
    #expect(StudyView.referenceWidth(question: paragraph, answer: .leading) == 354)
  }

  /// Amended 2026-11-22 (user): "Who composed The Magic Flute?" wraps, but its widest line fills ~68 % of the column,
  /// too little to set the answer's width. The drawn width counts, not the measured one with its break space.
  @Test func layoutDLeavesALeadingAnswerTheColumnUnderANarrowWrappingQuestion() {
    let magicFlute = StudyView.TextMeasure(width: 263, drawnWidth: 256, height: 68, twoLines: 68, column: 370)
    #expect(StudyView.referenceWidth(question: magicFlute, answer: .leading) == nil)
    let breakSpace = StudyView.TextMeasure(width: 316, drawnWidth: 312, height: 68, twoLines: 68, column: 370)
    #expect(StudyView.referenceWidth(question: breakSpace, answer: .leading) == nil)  // 85.4 % measured, 84.3 % drawn
  }

  /// Amended 2026-11-22 (user): an answer that isn't leading isn't constrained by the question's width.
  @Test func layoutDLeavesACentredAnswerTheColumn() {
    let paragraph = StudyView.TextMeasure(width: 360, drawnWidth: 354, height: 112, twoLines: 56, column: 370)
    #expect(StudyView.referenceWidth(question: paragraph, answer: .center) == nil)
    let line = StudyView.TextMeasure(width: 360, drawnWidth: 360, height: 34, twoLines: 34, column: 400)
    #expect(StudyView.referenceWidth(question: line, answer: .center) == nil)
  }

  /// Spec 017 reveal lift: the distance from the question centred in the card to its place in the centred pair, or
  /// the top when the pair overflows; up to `Spacing.xl` (40 pt) the question starts in place.
  @Test func revealLiftStartsAboveFortyPoints() {
    #expect(StudyView.revealLift(card: 650, question: 100, pair: 178) == 0)  // 39 pt
    #expect(StudyView.revealLift(card: 650, question: 100, pair: 180) == 0)  // 40 pt
    #expect(StudyView.revealLift(card: 650, question: 100, pair: 182) == 41)
  }

  @Test func revealLiftOfAnOverflowingPairEndsAtTheTop() {
    #expect(StudyView.revealLift(card: 650, question: 100, pair: 900) == 275)
  }

  @Test func revealLiftOfAnOverflowingQuestionIsZero() {
    #expect(StudyView.revealLift(card: 650, question: 800, pair: 900) == 0)
  }

  /// SwiftUI measures "Who composed The " with its break space; the line is drawn without it. Laid out greedily,
  /// "Magic" would fit on the first line: the standard strategy pushes it down, as SwiftUI does.
  @Test func drawnWidthIsTheWidestLineWithoutItsBreakSpace() {
    let font = CardFont.cardFaceMedium.uiFont(.large)
    func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    let drawn = StudyView.drawnWidth(of: "Who composed The Magic Flute?", font: font, in: 370)
    #expect(abs(drawn - width("Who composed The")) < 0.5, "\(drawn) vs \(width("Who composed The"))")
    #expect(abs(StudyView.drawnWidth(of: "la mer", font: font, in: 370) - width("la mer")) < 0.5)
  }

  @Test func layoutDKeepsALeadingAnswerInsideANearlyFullSingleLine() {
    func line(_ width: CGFloat) -> StudyView.TextMeasure {
      StudyView.TextMeasure(width: width, drawnWidth: width, height: 34, twoLines: 34, column: 400)
    }
    #expect(StudyView.referenceWidth(question: line(340), answer: .leading) == 340)  // exactly 85 %
    #expect(StudyView.referenceWidth(question: line(339), answer: .leading) == nil)  // short: the answer keeps the column
    #expect(StudyView.referenceWidth(question: line(120), answer: .leading) == nil)
    #expect(StudyView.referenceWidth(question: StudyView.TextMeasure(), answer: .leading) == nil)  // not measured yet
  }
}
