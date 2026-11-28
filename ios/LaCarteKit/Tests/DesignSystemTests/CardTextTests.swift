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
    #expect(CardText.answerFont(text(24), prompt: "la mer") == .cardAnswer)
    #expect(CardText.answerFont(text(24), prompt: text(60)) == .cardAnswer)
    #expect(CardText.answerFont(text(25), prompt: "la mer") == .body)
    #expect(CardText.answerFont("one\ntwo", prompt: "la mer") == .body)
  }

  @Test func aShortAnswerUnderALongPromptTakesThePromptsTier() {
    #expect(CardText.answerFont(text(7), prompt: text(61)) == .cardFaceSmall)
    #expect(CardText.answerFont(text(24), prompt: "one\ntwo") == .cardFaceSmall)
    #expect(CardText.answerFont(text(25), prompt: text(61)) == .body)
  }

  @Test func aLongPromptKeepsTheAnswerAtBody() {
    #expect(CardText.answerFont(text(60), prompt: text(61)) == .body)
  }
}
