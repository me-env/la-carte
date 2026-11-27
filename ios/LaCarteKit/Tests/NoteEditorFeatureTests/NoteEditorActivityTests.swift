import ActivityClient
import APIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import NoteEditorFeature

/// Spec 029 AC 27: what a save logs, never the field values.
@MainActor
struct NoteEditorActivityTests {
  let person = [Note].fixtures[0]
  let laCarte = [Note].fixtures[2]
  struct Offline: Error {}

  @Test func savingANewNoteLogsItsTypeAndDirections() async {
    let (store, logged) = makeStore(NoteEditorFeature.State())

    await store.send(.saveResponse(.success(person)))
    await store.receive(\.delegate.saved)
    await store.finish()
    #expect(logged.value == [.noteCreated(noteID: person.id, type: .person, directions: person.cards.count)])
  }

  @Test func savingAnExistingNoteLogsAnEditorEdit() async {
    let (store, logged) = makeStore(NoteEditorFeature.State(note: laCarte)) { [laCarte] in
      $0.apiClient.updateNote = { _, _ in laCarte }
    }

    await store.send(.saveButtonTapped) {
      $0.isSaving = true
    }
    await store.receive(\.saveResponse.success)
    await store.receive(\.delegate.saved)
    await store.finish()
    #expect(logged.value == [.noteEdited(noteID: laCarte.id, cardID: nil, source: .editor)])
  }

  @Test func aFailedSaveLogsAnAPIError() async {
    let (store, logged) = makeStore(NoteEditorFeature.State(note: laCarte)) {
      $0.apiClient.updateNote = { _, _ in throw URLError(.timedOut) }
    }

    await store.send(.saveButtonTapped) {
      $0.isSaving = true
    }
    await store.receive(\.saveResponse.failure) {
      $0.isSaving = false
      $0.saveFailed = true
    }
    await store.finish()
    #expect(logged.value == [.apiError(request: .updateNote, cardID: nil, status: 0, error: "timedOut")])
  }

  private func makeStore(
    _ state: NoteEditorFeature.State,
    _ dependencies: @escaping (inout DependencyValues) -> Void = { _ in }
  ) -> (TestStoreOf<NoteEditorFeature>, LockIsolated<[Activity]>) {
    let (activity, logged) = ActivityClient.recording()
    let store = TestStore(initialState: state) {
      NoteEditorFeature()
    } withDependencies: {
      $0.activity = activity
      $0.dismiss = DismissEffect {}
      dependencies(&$0)
    }
    return (store, logged)
  }
}
