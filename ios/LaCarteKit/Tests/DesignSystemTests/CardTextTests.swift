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
    #expect(CardText.answerFont(text(7), prompt: text(61)) == .body)
    #expect(CardText.answerFont("one\ntwo", prompt: "la mer") == .body)
  }

  @Test func promptAlignmentIsLeadingOnlyWhenLong() {
    #expect(CardText.promptAlignment(text(24)) == .center)
    #expect(CardText.promptAlignment(text(60)) == .center)
    #expect(CardText.promptAlignment(text(61)) == .leading)
    #expect(CardText.promptAlignment("abcd\nefghi") == .leading)
  }

  @Test func answerAlignmentFollowsALongAnswerOrALongPrompt() {
    #expect(CardText.answerAlignment(text(60), prompt: text(60)) == .center)
    #expect(CardText.answerAlignment(text(61), prompt: "la mer") == .leading)
    #expect(CardText.answerAlignment("the sea", prompt: text(61)) == .leading)
    #expect(CardText.answerAlignment(text(60), prompt: text(61)) == .leading)
    #expect(CardText.answerFont(text(60), prompt: text(61)) == .body)
    #expect(CardText.answerAlignment("one\ntwo", prompt: "la mer") == .leading)
  }
}
