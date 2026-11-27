import ActivityClient
@testable import APIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import DeckFeature

/// Spec 029 AC 28: what the deck logs, never the search text.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DeckActivityTests {
  // Alone in its test bundle; see "Main serial executor" in docs/testing.md.
  init() { uncheckedUseMainSerialExecutor = true }

  let notes = [Note].fixtures

  @Test func aLoadAndASearchLogTheCountAndWhetherAQueryWasActive() async {
    let clock = TestClock()
    let (store, logged) = makeStore { [notes] in
      $0.continuousClock = clock
      $0.apiClient.notes = { query in query == nil ? notes : [notes[0]] }
    }

    await store.send(.onAppear)
    await store.receive(\.notesResponse.success) {
      $0.notes = IdentifiedArray(uniqueElements: self.notes)
      $0.phase = .loaded
    }
    await store.send(\.binding.query, "ser") {
      $0.query = "ser"
    }
    await clock.advance(by: .seconds(0.3))
    await store.receive(\.notesResponse.success) {
      $0.notes = [self.notes[0]]
    }

    #expect(logged.value == [.deckLoaded(count: notes.count, query: false), .deckLoaded(count: 1, query: true)])
  }

  @Test func aDeleteLogsTheDeletedNote() async {
    var state = DeckFeature.State()
    state.notes = IdentifiedArray(uniqueElements: notes)
    state.phase = .loaded
    let (store, logged) = makeStore(state) { [notes] in
      $0.apiClient.deleteNote = { _ in }
      $0.apiClient.notes = { _ in Array(notes.dropFirst()) }
    }

    await store.send(.rowSwipedToDelete(notes[0].id)) {
      $0.notes.remove(id: self.notes[0].id)
      $0.deletions = 1
    }
    await store.receive(\.deleteResponse.success)
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.notesResponse.success)

    #expect(logged.value == [.noteDeleted(noteID: notes[0].id), .deckLoaded(count: notes.count - 1, query: false)])
  }

  private func makeStore(
    _ state: DeckFeature.State = DeckFeature.State(),
    _ dependencies: @escaping (inout DependencyValues) -> Void
  ) -> (TestStoreOf<DeckFeature>, LockIsolated<[Activity]>) {
    let (activity, logged) = ActivityClient.recording()
    let store = TestStore(initialState: state) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.activity = activity
      dependencies(&$0)
    }
    return (store, logged)
  }
}
