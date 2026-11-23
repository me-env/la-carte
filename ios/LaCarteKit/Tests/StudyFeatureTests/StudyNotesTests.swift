@testable import APIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import StudyFeature

/// Spec 014d: a card shows its note's fields per direction.
@MainActor
struct StudyNotesTests {
  let person = [Note].fixtures[0]
  var photoToNameAndDescription: Card { Card(note: person, card: person.cards[0]) }
  var reverse: Card {
    let note = [Note].fixtures[2]
    return Card(note: note, card: note.cards[1])
  }
  var basic: Card { [Card].fixtures[0] }

  @Test func onlyCardsWithOneTextFieldPerSideAreEditableInline() {
    #expect(revealed(basic).canEditInline)
    #expect(revealed(reverse).canEditInline)
    for card in person.cards {
      #expect(!revealed(Card(note: person, card: card)).canEditInline)
    }
    var photoToName = photoToNameAndDescription
    photoToName.answer = ["name"]
    #expect(!revealed(photoToName).canEditInline)
    var nameToDescription = photoToNameAndDescription
    nameToDescription.prompt = ["name"]
    nameToDescription.answer = ["description"]
    #expect(!revealed(nameToDescription).canEditInline)  // a person card is never edited in place (014d #9)
  }

  @Test func doubleTappingAPersonCardDoesNothing() async {
    let store = TestStore(initialState: revealed(photoToNameAndDescription)) { StudyFeature() }

    await store.send(.textDoubleTapped(.front))
    await store.send(.textDoubleTapped(.back))
  }

  @Test func aReverseCardEditsItsShownSidesFromTheNotesFields() async {
    let updates = LockIsolated<[(String, String)]>([])
    var card = reverse
    card.front = "stale"
    let store = TestStore(initialState: revealed(card)) {
      StudyFeature()
    } withDependencies: { [reverse] in
      $0.apiClient.updateCard = { _, front, back in
        updates.withValue { $0.append((front, back)) }
        var card = reverse
        card.setText(front, for: .front)
        return card
      }
    }

    await store.send(.textDoubleTapped(.front)) {
      $0.editing = .front
      $0.draft = "the menu — and the map"
    }
    await store.send(.draftChanged("the menu")) {
      $0.draft = "the menu"
    }
    await store.send(.editEnded) {
      $0.editing = nil
      $0.cards[0].fields["back"] = "the menu"
      $0.cards[0].front = "the menu"
      $0.isSavingEdit = true
    }
    await store.receive(\.editSaveResponse) {
      $0.isSavingEdit = false
    }
    #expect(updates.value.map(\.0) == ["the menu"])
    #expect(updates.value.map(\.1) == ["la carte"])
  }

  @Test func aPersonCardHintsAtItsNonEmptyAnswerFields() {
    #expect(revealed(photoToNameAndDescription).answerHint == "Name and description?")
    #expect(revealed(Card(note: person, card: person.cards[2])).answerHint == "Photo and name?")
    var card = photoToNameAndDescription
    card.fields["description"] = ""
    #expect(revealed(card).answerHint == "Name?")
    #expect(revealed(basic).answerHint == nil)
  }

  @Test func emptyFieldsAreNotShown() {
    var card = photoToNameAndDescription
    card.fields["description"] = ""
    #expect(card.shown(card.answer) == ["name"])
  }

  private func revealed(_ card: Card) -> StudyFeature.State {
    var state = StudyFeature.State()
    state.cards = [card]
    state.phase = .studying
    state.isRevealed = true
    return state
  }
}
