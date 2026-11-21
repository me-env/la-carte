import APIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import CardEditorFeature

@MainActor
struct CardEditorFeatureTests {
  let card = [Card].fixtures[0]
  struct Offline: Error {}

  @Test func newCardStartsEmptyAndEditPrefills() {
    let new = CardEditorFeature.State()
    #expect(new.card == nil)
    #expect(new.front == "")
    #expect(new.back == "")

    let edit = CardEditorFeature.State(card: card)
    #expect(edit.card == card)
    #expect(edit.front == card.front)
    #expect(edit.back == card.back)
  }

  @Test func savingANewCardAddsItAndDismisses() async {
    let added = LockIsolated<[String]>([])
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: CardEditorFeature.State()) {
      CardEditorFeature()
    } withDependencies: { [card] in
      $0.apiClient.addCard = { front, back in
        added.withValue { $0 = [front, back] }
        return card
      }
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    await store.send(\.binding.front, " chat ") {
      $0.front = " chat "
    }
    await store.send(\.binding.back, "cat\n") {
      $0.back = "cat\n"
    }
    await store.send(.saveButtonTapped) {
      $0.isSaving = true
    }
    await store.receive(\.saveResponse.success)
    await store.receive(\.delegate.saved, card)
    #expect(added.value == ["chat", "cat"])
    #expect(dismissed.value)
  }

  @Test func savingAnEditUpdatesTheCardAndDismisses() async {
    var updated = card
    updated.back = "a happy accident"
    let patched = LockIsolated<[String]>([])
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: CardEditorFeature.State(card: card)) {
      CardEditorFeature()
    } withDependencies: { [updated] in
      $0.apiClient.updateCard = { id, front, back in
        patched.withValue { $0 = [id.uuidString, front, back] }
        return updated
      }
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    await store.send(\.binding.back, "a happy accident") {
      $0.back = "a happy accident"
    }
    await store.send(.saveButtonTapped) {
      $0.isSaving = true
    }
    await store.receive(\.saveResponse.success)
    await store.receive(\.delegate.saved, updated)
    #expect(patched.value == [card.id.uuidString, card.front, "a happy accident"])
    #expect(dismissed.value)
  }

  @Test func saveIsDisabledWhileATrimmedFieldIsEmptyOrASaveIsInFlight() async {
    let (responses, respond) = AsyncStream.makeStream(of: Card.self)
    let saveCount = LockIsolated(0)
    let store = TestStore(initialState: CardEditorFeature.State()) {
      CardEditorFeature()
    } withDependencies: {
      $0.apiClient.addCard = { _, _ in
        saveCount.withValue { $0 += 1 }
        for await card in responses { return card }
        throw CancellationError()
      }
      $0.dismiss = DismissEffect {}
    }

    #expect(!store.state.canSave)
    await store.send(\.binding.front, "chat") {
      $0.front = "chat"
    }
    await store.send(\.binding.back, "  \n ") {
      $0.back = "  \n "
    }
    #expect(!store.state.canSave)
    await store.send(.saveButtonTapped)

    await store.send(\.binding.back, "cat") {
      $0.back = "cat"
    }
    #expect(store.state.canSave)
    await store.send(.saveButtonTapped) {
      $0.isSaving = true
    }
    #expect(!store.state.canSave)
    await store.send(.saveButtonTapped)

    respond.yield(card)
    await store.receive(\.saveResponse.success)
    await store.receive(\.delegate.saved)
    #expect(saveCount.value == 1)
  }

  @Test func saveFailureKeepsTheTextAndShowsTheError() async {
    var state = CardEditorFeature.State()
    state.front = "chat"
    state.back = "cat"
    let store = TestStore(initialState: state) {
      CardEditorFeature()
    } withDependencies: {
      $0.apiClient.addCard = { _, _ in throw Offline() }
    }

    await store.send(.saveButtonTapped) {
      $0.isSaving = true
    }
    await store.receive(\.saveResponse.failure) {
      $0.isSaving = false
      $0.saveFailed = true
    }
    #expect(store.state.canSave)
  }

  @Test func closeWithoutChangesDismissesWithoutCallingTheAPI() async {
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: CardEditorFeature.State(card: card)) {
      CardEditorFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    #expect(!store.state.hasChanges)
    await store.send(.closeButtonTapped)
    #expect(dismissed.value)
  }

  @Test func whitespaceOnlyChangeCountsAsNoChange() async {
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: CardEditorFeature.State(card: card)) {
      CardEditorFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    await store.send(\.binding.front, " \(card.front)\n") {
      $0.front = " \(card.front)\n"
    }
    #expect(!store.state.hasChanges)
    await store.send(.closeButtonTapped)
    #expect(dismissed.value)
  }

  @Test func closeWithChangesAsksBeforeDiscarding() async {
    let store = TestStore(initialState: CardEditorFeature.State()) {
      CardEditorFeature()
    }

    await store.send(\.binding.back, "cat") {
      $0.back = "cat"
    }
    #expect(store.state.hasChanges)
    await store.send(.closeButtonTapped) {
      $0.isDiscardDialogPresented = true
    }
  }

  @Test func keepEditingClosesTheDialogAndKeepsTheText() async {
    var state = CardEditorFeature.State(card: card)
    state.back = "a happy accident"
    state.isDiscardDialogPresented = true
    let store = TestStore(initialState: state) {
      CardEditorFeature()
    }

    await store.send(\.binding.isDiscardDialogPresented, false) {
      $0.isDiscardDialogPresented = false
    }
    #expect(store.state.back == "a happy accident")
  }

  @Test func discardDismisses() async {
    let dismissed = LockIsolated(false)
    var state = CardEditorFeature.State(card: card)
    state.back = "a happy accident"
    state.isDiscardDialogPresented = true
    let store = TestStore(initialState: state) {
      CardEditorFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    await store.send(.discardTapped)
    #expect(dismissed.value)
  }
}
