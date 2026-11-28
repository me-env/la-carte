import SwiftUI
import Testing

@testable import DesignSystem

/// Spec 017: a card side's size and alignment come from its length.
struct CardTextTests {
  func text(_ count: Int) -> String { String(repeating: "a", count: count) }

  @Test func promptFontShrinksWithLength() {
    #expect(CardText.promptFont(text(24)) == .cardFace)
    #expect(CardText.promptFont(text(25)) == .cardFaceMedium)
    #expect(CardText.promptFont(text(60)) == .cardFaceMedium)
    #expect(CardText.promptFont(text(61)) == .cardFaceSmall)
    #expect(CardText.promptFont("abcd\nefghi") == .cardFaceSmall)
  }

  @Test func surroundingWhitespaceIsNotCounted() {
    #expect(CardText.promptFont("  \n" + text(24) + " \n") == .cardFace)
    #expect(CardText.promptFont(" " + text(60) + "\n") == .cardFaceMedium)
    #expect(!CardText.isLong(" " + text(60) + "\n"))
  }

  @Test func answerFontStaysBelowTheQuestion() {
    #expect(CardText.answerFont(text(24), questionLeads: false) == .cardAnswer)
    #expect(CardText.answerFont(text(25), questionLeads: false) == .body)
    #expect(CardText.answerFont("one\ntwo", questionLeads: false) == .body)
  }

  /// #16: only a leading question lifts a short answer to its tier; a centred one, however long, stays as today.
  @Test func aShortAnswerUnderALeadingQuestionTakesItsTier() {
    #expect(CardText.answerFont(text(7), questionLeads: true) == .cardFaceSmall)
    #expect(CardText.answerFont(text(24), questionLeads: true) == .cardFaceSmall)
    #expect(CardText.answerFont(text(25), questionLeads: true) == .body)
    #expect(CardText.answerFont(text(60), questionLeads: true) == .body)
  }
}
