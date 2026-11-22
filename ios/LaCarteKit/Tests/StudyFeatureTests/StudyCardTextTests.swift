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
    #expect(card.answerFont == .body)

    let nameOnly = self.card(prompt: ["photo"], answer: ["photo", "name"])
    #expect(nameOnly.answerFont == .cardAnswer)
  }
}

/// Spec 017 alignment: 3+ rendered lines are leading; layout C snaps only nearly equal blocks that still fit.
@MainActor
struct StudyTextLayoutTests {
  @Test func threeRenderedLinesAreMultiline() {
    #expect(!StudyView.TextMeasure(width: 100, height: 26, twoLines: 26).isMultiline)
    #expect(!StudyView.TextMeasure(width: 100, height: 52, twoLines: 52).isMultiline)
    #expect(StudyView.TextMeasure(width: 100, height: 78, twoLines: 52).isMultiline)
  }

  @Test func layoutCSnapsNearlyEqualBlocksThatStillFit() {
    #expect(StudyView.snap(answer: 300, toQuestion: 280, column: 370) == 10)
    #expect(StudyView.snap(answer: 280, toQuestion: 300, column: 370) == -10)
    #expect(StudyView.snap(answer: 200, toQuestion: 300, column: 370) == 0)  // clearly different: left centred
    #expect(StudyView.snap(answer: 360, toQuestion: 340, column: 370) == 0)  // would cross the right margin
  }
}
