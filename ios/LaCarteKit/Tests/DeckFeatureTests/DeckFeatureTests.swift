@testable import APIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import DeckFeature
@testable import NoteEditorFeature
@testable import SettingsFeature

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DeckFeatureTests {
  // TestStore waits by hopping through background-priority tasks, which a loaded CI runner left
  // unscheduled past the time limit; the main serial executor runs them on the main actor. This suite is
  // alone in its test process, so the switch stays on.
  init() { uncheckedUseMainSerialExecutor = true }

  let notes = [Note].fixtures
  struct Offline: Error {}

  @Test func appearLoadsEveryNoteInAPIOrder() async {
    let store = TestStore(initialState: DeckFeature.State()) {
      DeckFeature()
    } withDependencies: { [notes] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.notes = { query in
        #expect(query == nil)
        return notes
      }
    }

    await store.send(.onAppear)
    await store.receive(\.notesResponse.success) {
      $0.notes = IdentifiedArray(uniqueElements: self.notes)
      $0.phase = .loaded
    }
    #expect(store.state.message == nil)
  }

  @Test func dueTextSaysNowOnceDueAndRelativeTimeBefore() {
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    let english = Locale(identifier: "en_US")
    #expect(DeckView.dueText(now, now: now, locale: english) == "Due now")
    #expect(DeckView.dueText(now.addingTimeInterval(-60), now: now, locale: english) == "Due now")
    #expect(DeckView.dueText(now.addingTimeInterval(3 * 86_400 + 60), now: now, locale: english) == "Due in 3 days")
  }

  @Test func searchIsDebouncedAndClearingShowsEveryNote() async {
    let clock = TestClock()
    let queries = LockIsolated<[String?]>([])
    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: { [notes] in
      $0.apiClient.isConfigured = { true }
      $0.continuousClock = clock
      $0.apiClient.notes = { query in
        queries.withValue { $0.append(query) }
        return query == "ser" ? [notes[0]] : notes
      }
    }

    await store.send(\.binding.query, "s") {
      $0.query = "s"
    }
    await clock.advance(by: .seconds(0.2))
    await store.send(\.binding.query, "ser") {
      $0.query = "ser"
    }
    await clock.advance(by: .seconds(0.29))
    #expect(queries.value.isEmpty)
    await clock.advance(by: .seconds(0.01))
    await store.receive(\.notesResponse.success) {
      $0.notes = [self.notes[0]]
    }

    await store.send(\.binding.query, "") {
      $0.query = ""
    }
    await clock.advance(by: .seconds(0.3))
    await store.receive(\.notesResponse.success) {
      $0.notes = IdentifiedArray(uniqueElements: self.notes)
    }
    #expect(queries.value == ["ser", nil])
  }

  /// QA ci-ios26-triage D1: deleting "ser" quickly must end on every note, never on the "s" results.
  @Test func deletingTheQueryQuicklyCancelsPendingSearchesAndShowsEveryNote() async {
    let clock = TestClock()
    let queries = LockIsolated<[String?]>([])
    var state = loaded([notes[0]])
    state.query = "ser"
    let store = TestStore(initialState: state) {
      DeckFeature()
    } withDependencies: { [notes] in
      $0.apiClient.isConfigured = { true }
      $0.continuousClock = clock
      $0.apiClient.notes = { query in
        queries.withValue { $0.append(query) }
        return query == "s" ? [notes[0], notes[2]] : notes
      }
    }

    await store.send(\.binding.query, "se") {
      $0.query = "se"
    }
    await clock.advance(by: .seconds(0.1))
    await store.send(\.binding.query, "s") {
      $0.query = "s"
    }
    await clock.advance(by: .seconds(0.29))
    await store.send(\.binding.query, "") {
      $0.query = ""
    }
    await clock.advance(by: .seconds(0.3))
    await store.receive(\.notesResponse.success) {
      $0.notes = IdentifiedArray(uniqueElements: self.notes)
    }
    #expect(queries.value == [nil])
  }

  @Test func emptyListsSayWhy() async {
    var state = DeckFeature.State()
    #expect(state.message == nil)
    state.phase = .loaded
    #expect(state.message == .noCards)
    state.query = "zzz"
    #expect(state.message == .noMatches)

    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.notes = { _ in throw Offline() }
    }

    await store.send(.onAppear)
    await store.receive(\.notesResponse.failure) {
      $0.notes = []
      $0.phase = .offline
    }
    #expect(store.state.message == .offline)
  }

  @Test func retryReloadsAfterGoingOffline() async {
    var state = DeckFeature.State()
    state.phase = .offline
    let store = TestStore(initialState: state) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.notes = { [notes] _ in notes }
    }

    await store.send(.retryButtonTapped) {
      $0.phase = .loading
    }
    await store.receive(\.notesResponse.success) {
      $0.notes = IdentifiedArray(uniqueElements: self.notes)
      $0.phase = .loaded
    }
  }

  @Test func swipingDeletesTheRowAndTellsTheParent() async {
    let deck = LockIsolated(notes)
    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.deleteNote = { id in deck.withValue { $0.removeAll { $0.id == id } } }
      $0.apiClient.notes = { _ in deck.value }
    }

    await store.send(.rowSwipedToDelete(notes[1].id)) {
      $0.notes.remove(id: self.notes[1].id)
      $0.deletions = 1
    }
    await store.receive(\.deleteResponse.success)
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.notesResponse.success)
    #expect(deck.value.map(\.id) == [notes[0].id, notes[2].id, notes[3].id])
  }

  /// Spec 009a #5: each message keeps its copy and gets its system symbol.
  @Test func messagesHaveTheirTitleAndSymbol() {
    let expected: [(DeckFeature.State.Message, String, String)] = [
      (.noCards, "No cards yet", "rectangle.stack"),
      (.offline, "Can't reach your deck", "wifi.slash"),
      (.notSetUp, "Connect your deck", "link"),
      (.unauthorized, "Token rejected", "key"),
    ]
    for (message, title, symbol) in expected {
      #expect(message.title == title)
      #expect(message.systemImage == symbol)
    }
  }

  /// Spec 009a #7: every delete, from the swipe or the context menu, bumps the light-impact haptic trigger.
  @Test func everyDeleteBumpsTheHapticTrigger() async {
    let deck = LockIsolated(notes)
    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.deleteNote = { id in deck.withValue { $0.removeAll { $0.id == id } } }
      $0.apiClient.notes = { _ in deck.value }
    }

    for (index, note) in notes.prefix(2).enumerated() {
      await store.send(.rowSwipedToDelete(note.id)) {
        $0.notes.remove(id: note.id)
        $0.deletions = index + 1
      }
      await store.receive(\.deleteResponse.success)
      await store.receive(\.delegate.deckChanged)
      await store.receive(\.notesResponse.success)
    }
  }

  @Test func failedDeleteReloadsTheList() async {
    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: { [notes] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.deleteNote = { _ in throw Offline() }
      $0.apiClient.notes = { _ in notes }
    }

    await store.send(.rowSwipedToDelete(notes[1].id)) {
      $0.notes.remove(id: self.notes[1].id)
      $0.deletions = 1
    }
    await store.receive(\.deleteResponse.failure)
    await store.receive(\.notesResponse.success) {
      $0.notes = IdentifiedArray(uniqueElements: self.notes)
    }
  }

  @Test func swipingCancelsALoadInFlightSoTheRowCantComeBack() async {
    let deck = LockIsolated(notes)
    let loads = LockIsolated(0)
    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      // Only cancellation ends the first load: if the swipe didn't cancel it, the store would finish with it in flight.
      $0.apiClient.notes = { _ in
        let load = loads.withValue { $0 += 1; return $0 }
        if load == 1 { try await Task.never() }
        return deck.value
      }
      $0.apiClient.deleteNote = { id in deck.withValue { $0.removeAll { $0.id == id } } }
    }

    await store.send(.onAppear)
    await store.send(.rowSwipedToDelete(notes[1].id)) {
      $0.notes.remove(id: self.notes[1].id)
      $0.deletions = 1
    }
    await store.receive(\.deleteResponse.success)
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.notesResponse.success)
    #expect(store.state.notes.ids == [notes[0].id, notes[2].id, notes[3].id])
    #expect(loads.value == 2)
  }

  @Test func deletingDuringAPendingSearchShowsResultsForTheField() async {
    let clock = TestClock()
    let queries = LockIsolated<[String?]>([])
    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: { [notes] in
      $0.apiClient.isConfigured = { true }
      $0.continuousClock = clock
      $0.apiClient.notes = { query in
        queries.withValue { $0.append(query) }
        return query == "ser" ? [notes[0]] : notes
      }
      $0.apiClient.deleteNote = { _ in }
    }

    await store.send(\.binding.query, "ser") {
      $0.query = "ser"
    }
    await store.send(.rowSwipedToDelete(notes[1].id)) {
      $0.notes.remove(id: self.notes[1].id)
      $0.deletions = 1
    }
    await store.receive(\.deleteResponse.success)
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.notesResponse.success) {
      $0.notes = [self.notes[0]]
    }
    #expect(queries.value == ["ser"])
  }

  @Test func aSuccessfulConnectionTestReloadsTheDeckAndTellsTheParent() async {
    let other = Array(notes.prefix(1))
    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.stats = { DeckStats(total: 1, due: 1, new: 1, reviewedToday: 0, nextDue: nil) }
      $0.apiClient.notes = { _ in other }
    }

    await store.send(.settingsButtonTapped) {
      $0.destination = .settings(SettingsFeature.State())
    }
    await store.send(\.destination.settings.testButtonTapped) {
      $0.destination?.modify(\.settings) { $0.connection = .checking }
    }
    await store.receive(\.destination.settings.statsResponse.success) {
      $0.destination?.modify(\.settings) { $0.connection = .connected(total: 1) }
    }
    await store.receive(\.destination.settings.delegate.serverChanged)
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.notesResponse.success) {
      $0.notes = IdentifiedArray(uniqueElements: other)
    }
  }

  @Test func aTokenEditIsSavedEvenWhenSettingsIsSwipedAwayRightAfter() async {
    let saved = LockIsolated<[String?]>([])
    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.notes = { _ in [] }
      $0.tokenStore.save = { token in saved.withValue { $0.append(token) } }
    }

    await store.send(.settingsButtonTapped) {
      $0.destination = .settings(SettingsFeature.State())
    }
    await store.send(\.destination.settings.binding.token, "s3") {
      $0.destination?.modify(\.settings) { $0.token = "s3" }
    }
    // Dismissal cancels the child's effects; the save already ran.
    await store.send(\.destination.dismiss) {
      $0.destination = nil
    }
    #expect(saved.value == ["s3"])
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.notesResponse.success) {
      $0.notes = []
    }
  }

  @Test func withoutAServerOrTokenTheDeckAsksToConnectWithoutARequest() async {
    // `notes` is unimplemented: calling it fails the test.
    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { false }
    }

    await store.send(.onAppear) {
      $0.notes = []
      $0.phase = .notSetUp
    }
    #expect(store.state.message == .notSetUp)
    #expect(store.state.showsSettingsButton)
  }

  @Test func aRejectedTokenSaysSoAndOffersSettings() async {
    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.notes = { _ in throw APIError(statusCode: 403, message: "Forbidden") }
    }

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.notesResponse.failure) {
      $0.notes = []
      $0.phase = .unauthorized
    }
    #expect(store.state.message == .unauthorized)
    #expect(store.state.showsSettingsButton)
  }

  @Test func onlySetupProblemsOfferSettings() {
    var state = DeckFeature.State()
    for phase in [DeckFeature.State.Phase.loading, .loaded, .offline] {
      state.phase = phase
      #expect(!state.showsSettingsButton)
    }
  }

  @Test func closingSettingsReloadsWithTheQueryAndTellsTheParent() async {
    var state = loaded(notes)
    state.query = "ser"
    state.destination = .settings(SettingsFeature.State())
    let store = TestStore(initialState: state) {
      DeckFeature()
    } withDependencies: { [notes] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.notes = { query in
        #expect(query == "ser")
        return [notes[1]]
      }
    }

    await store.send(\.destination.dismiss) {
      $0.destination = nil
    }
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.notesResponse.success) {
      $0.notes = [self.notes[1]]
    }
  }

  @Test func closingTheEditorDoesNotReload() async {
    var state = loaded(notes)
    state.destination = .editor(NoteEditorFeature.State())
    // `notes` is unimplemented: a reload fails the test.
    let store = TestStore(initialState: state) { DeckFeature() }

    await store.send(\.destination.dismiss) {
      $0.destination = nil
    }
  }

  @Test func tappingARowEditsItAndSavingReplacesTheRow() async {
    var updated = notes[1]
    updated.fields["back"] = "the menu"
    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: { [updated] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.updateNote = { _, _ in updated }
    }

    await store.send(.rowTapped(notes[1].id)) {
      $0.destination = .editor(NoteEditorFeature.State(note: self.notes[1]))
    }
    await store.send(\.destination.editor.fieldChanged, ("back", "the menu")) {
      $0.destination?.modify(\.editor) { $0.fields["back"] = "the menu" }
    }
    await store.send(\.destination.editor.saveButtonTapped) {
      $0.destination?.modify(\.editor) { $0.isSaving = true }
    }
    await store.receive(\.destination.editor.saveResponse.success)
    await store.receive(\.destination.editor.delegate.saved) {
      $0.notes[id: updated.id] = updated
    }
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.destination.dismiss) {
      $0.destination = nil
    }
    #expect(store.state.notes.ids == IdentifiedArray(uniqueElements: notes).ids)
  }

  @Test func addingANotePutsItAtTheTop() async {
    let date = Date(timeIntervalSince1970: 1_795_000_000)
    let new = Note(
      id: UUID(1), type: .basic, fields: ["front": "chat", "back": "cat"],
      cards: [Note.Card(id: UUID(2), prompt: ["front"], answer: ["back"], due: date)],
      createdAt: date, updatedAt: date
    )
    let store = TestStore(initialState: loaded(notes)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.addNote = { _ in new }
    }

    await store.send(.addButtonTapped) {
      $0.destination = .editor(NoteEditorFeature.State())
    }
    await store.send(\.destination.editor.fieldChanged, ("front", "chat")) {
      $0.destination?.modify(\.editor) { $0.fields["front"] = "chat" }
    }
    await store.send(\.destination.editor.fieldChanged, ("back", "cat")) {
      $0.destination?.modify(\.editor) {
        $0.fields["back"] = "cat"
        $0.directions = [Direction(prompt: ["front"], answer: ["back"])]
      }
    }
    await store.send(\.destination.editor.saveButtonTapped) {
      $0.destination?.modify(\.editor) { $0.isSaving = true }
    }
    await store.receive(\.destination.editor.saveResponse.success)
    await store.receive(\.destination.editor.delegate.saved) {
      $0.notes.insert(new, at: 0)
    }
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.destination.dismiss) {
      $0.destination = nil
    }
  }

  @Test func onlyBecomingActiveReloadsWithTheQuery() async {
    let queries = LockIsolated<[String?]>([])
    var state = loaded([notes[0]])
    state.query = "ser"
    let store = TestStore(initialState: state) {
      DeckFeature()
    } withDependencies: { [notes] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.notes = { query in
        queries.withValue { $0.append(query) }
        return notes
      }
    }

    await store.send(.scenePhaseChanged(.inactive))
    await store.send(.scenePhaseChanged(.background))
    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.notesResponse.success) {
      $0.notes = IdentifiedArray(uniqueElements: self.notes)
    }
    #expect(queries.value == ["ser"])
  }

  @Test func rowsShowTheKeyFieldTheAnswerOrRoleAndHowManyDirections() {
    let person = notes[0]
    #expect(person.title == "Ada Example")
    #expect(person.subtitle == "runs the bakery")
    #expect(person.stateText == "3 directions")
    #expect(person.photoURL != nil)

    let basic = notes[1]
    #expect(basic.title == "serendipity")
    #expect(basic.subtitle == "finding something good without looking for it")
    #expect(basic.stateText == "new")
    #expect(basic.photoURL == nil)
    #expect(notes[2].stateText == "2 directions")
  }

  @Test func aRowIsDueWhenItsEarliestCardIs() {
    var note = notes[0]
    let early = Date(timeIntervalSince1970: 1_000)
    note.cards[1].due = early
    #expect(note.due == early)
  }

  private func loaded(_ notes: [Note]) -> DeckFeature.State {
    var state = DeckFeature.State()
    state.notes = IdentifiedArray(uniqueElements: notes)
    state.phase = .loaded
    return state
  }
}
