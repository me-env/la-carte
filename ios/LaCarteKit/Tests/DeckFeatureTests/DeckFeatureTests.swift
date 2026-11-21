@testable import APIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import CardEditorFeature
@testable import DeckFeature
@testable import SettingsFeature

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DeckFeatureTests {
  let cards = [Card].fixtures
  struct Offline: Error {}

  @Test func appearLoadsEveryCardInAPIOrder() async {
    let store = TestStore(initialState: DeckFeature.State()) {
      DeckFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.cards = { query in
        #expect(query == nil)
        return cards
      }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.success) {
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
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

  @Test func searchIsDebouncedAndClearingShowsEveryCard() async {
    let clock = TestClock()
    let queries = LockIsolated<[String?]>([])
    let store = TestStore(initialState: loaded(cards)) {
      DeckFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.continuousClock = clock
      $0.apiClient.cards = { query in
        queries.withValue { $0.append(query) }
        return query == "ser" ? [cards[0]] : cards
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
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[0]]
    }

    await store.send(\.binding.query, "") {
      $0.query = ""
    }
    await clock.advance(by: .seconds(0.3))
    await store.receive(\.cardsResponse.success) {
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
    }
    #expect(queries.value == ["ser", nil])
  }

  /// QA ci-ios26-triage D1: deleting "ser" quickly must end on every card, never on the "s" results.
  @Test func deletingTheQueryQuicklyCancelsPendingSearchesAndShowsEveryCard() async {
    let clock = TestClock()
    let queries = LockIsolated<[String?]>([])
    var state = loaded([cards[0]])
    state.query = "ser"
    let store = TestStore(initialState: state) {
      DeckFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.continuousClock = clock
      $0.apiClient.cards = { query in
        queries.withValue { $0.append(query) }
        return query == "s" ? [cards[0], cards[2]] : cards
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
    await store.receive(\.cardsResponse.success) {
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
    }
    #expect(queries.value == [nil])
  }

  @Test func emptyListsSayWhy() async {
    var state = DeckFeature.State()
    #expect(state.message == nil)
    state.phase = .loaded
    #expect(state.message == "No cards yet")
    state.query = "zzz"
    #expect(state.message == "No matches")

    let store = TestStore(initialState: loaded(cards)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.cards = { _ in throw Offline() }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.failure) {
      $0.cards = []
      $0.phase = .offline
    }
    #expect(store.state.message == "Can't reach your deck")
  }

  @Test func swipingDeletesTheRowAndTellsTheParent() async {
    let deck = LockIsolated(cards)
    let store = TestStore(initialState: loaded(cards)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.deleteCard = { id in deck.withValue { $0.removeAll { $0.id == id } } }
      $0.apiClient.cards = { _ in deck.value }
    }

    await store.send(.rowSwipedToDelete(cards[1].id)) {
      $0.cards.remove(id: self.cards[1].id)
    }
    await store.receive(\.deleteResponse.success)
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.cardsResponse.success)
    #expect(deck.value.map(\.id) == [cards[0].id, cards[2].id])
  }

  @Test func failedDeleteReloadsTheList() async {
    let store = TestStore(initialState: loaded(cards)) {
      DeckFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.deleteCard = { _ in throw Offline() }
      $0.apiClient.cards = { _ in cards }
    }

    await store.send(.rowSwipedToDelete(cards[1].id)) {
      $0.cards.remove(id: self.cards[1].id)
    }
    await store.receive(\.deleteResponse.failure)
    await store.receive(\.cardsResponse.success) {
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
    }
  }

  @Test func swipingCancelsALoadInFlightSoTheRowCantComeBack() async {
    let clock = TestClock()
    let deck = LockIsolated(cards)
    let loads = LockIsolated(0)
    let store = TestStore(initialState: loaded(cards)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.continuousClock = clock
      $0.apiClient.cards = { _ in
        // Snapshot before the delete lands, like a slow response from the server.
        let snapshot = deck.value
        loads.withValue { $0 += 1 }
        try await clock.sleep(for: .seconds(1))
        return snapshot
      }
      $0.apiClient.deleteCard = { id in deck.withValue { $0.removeAll { $0.id == id } } }
    }

    await store.send(.onAppear)
    await store.send(.rowSwipedToDelete(cards[1].id)) {
      $0.cards.remove(id: self.cards[1].id)
    }
    await store.receive(\.deleteResponse.success)
    await store.receive(\.delegate.deckChanged)
    await clock.advance(by: .seconds(1))
    await store.receive(\.cardsResponse.success)
    #expect(store.state.cards.ids == [cards[0].id, cards[2].id])
    #expect(loads.value == 2)
  }

  @Test func deletingDuringAPendingSearchShowsResultsForTheField() async {
    let clock = TestClock()
    let queries = LockIsolated<[String?]>([])
    let store = TestStore(initialState: loaded(cards)) {
      DeckFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.continuousClock = clock
      $0.apiClient.cards = { query in
        queries.withValue { $0.append(query) }
        return query == "ser" ? [cards[0]] : cards
      }
      $0.apiClient.deleteCard = { _ in }
    }

    await store.send(\.binding.query, "ser") {
      $0.query = "ser"
    }
    await store.send(.rowSwipedToDelete(cards[1].id)) {
      $0.cards.remove(id: self.cards[1].id)
    }
    await store.receive(\.deleteResponse.success)
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[0]]
    }
    await clock.run()
    #expect(queries.value == ["ser"])
  }

  @Test func aSuccessfulConnectionTestReloadsTheDeckAndTellsTheParent() async {
    let other = Array(cards.prefix(1))
    let store = TestStore(initialState: loaded(cards)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.stats = { DeckStats(total: 1, due: 1, new: 1, reviewedToday: 0, nextDue: nil) }
      $0.apiClient.cards = { _ in other }
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
    await store.receive(\.cardsResponse.success) {
      $0.cards = IdentifiedArray(uniqueElements: other)
    }
  }

  @Test func aTokenEditIsSavedEvenWhenSettingsIsSwipedAwayRightAfter() async {
    let saved = LockIsolated<[String?]>([])
    let store = TestStore(initialState: loaded(cards)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.cards = { _ in [] }
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
    await store.receive(\.cardsResponse.success) {
      $0.cards = []
    }
  }

  @Test func withoutAServerOrTokenTheDeckAsksToConnectWithoutARequest() async {
    // `cards` is unimplemented: calling it fails the test.
    let store = TestStore(initialState: loaded(cards)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { false }
    }

    await store.send(.onAppear) {
      $0.cards = []
      $0.phase = .notSetUp
    }
    #expect(store.state.message == "Connect your deck")
    #expect(store.state.showsSettingsButton)
  }

  @Test func aRejectedTokenSaysSoAndOffersSettings() async {
    let store = TestStore(initialState: loaded(cards)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.cards = { _ in throw APIError(statusCode: 403, message: "Forbidden") }
    }

    await store.send(.pulledToRefresh)
    await store.receive(\.cardsResponse.failure) {
      $0.cards = []
      $0.phase = .unauthorized
    }
    #expect(store.state.message == "Token rejected")
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
    var state = loaded(cards)
    state.query = "ser"
    state.destination = .settings(SettingsFeature.State())
    let store = TestStore(initialState: state) {
      DeckFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.cards = { query in
        #expect(query == "ser")
        return [cards[1]]
      }
    }

    await store.send(\.destination.dismiss) {
      $0.destination = nil
    }
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[1]]
    }
  }

  @Test func closingTheEditorDoesNotReload() async {
    var state = loaded(cards)
    state.destination = .editor(CardEditorFeature.State())
    // `cards` is unimplemented: a reload fails the test.
    let store = TestStore(initialState: state) { DeckFeature() }

    await store.send(\.destination.dismiss) {
      $0.destination = nil
    }
  }

  @Test func tappingARowEditsItAndSavingReplacesTheRow() async {
    var updated = cards[1]
    updated.back = "the menu"
    let store = TestStore(initialState: loaded(cards)) {
      DeckFeature()
    } withDependencies: { [updated] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.updateCard = { _, _, _ in updated }
    }

    await store.send(.rowTapped(cards[1].id)) {
      $0.destination = .editor(CardEditorFeature.State(card: self.cards[1]))
    }
    await store.send(\.destination.editor.binding.back, "the menu") {
      $0.destination?.modify(\.editor) { $0.back = "the menu" }
    }
    await store.send(\.destination.editor.saveButtonTapped) {
      $0.destination?.modify(\.editor) { $0.isSaving = true }
    }
    await store.receive(\.destination.editor.saveResponse.success)
    await store.receive(\.destination.editor.delegate.saved) {
      $0.cards[id: updated.id] = updated
    }
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.destination.dismiss) {
      $0.destination = nil
    }
    #expect(store.state.cards.ids == IdentifiedArray(uniqueElements: cards).ids)
  }

  @Test func addingACardPutsItAtTheTop() async {
    let date = Date(timeIntervalSince1970: 1_795_000_000)
    let new = Card(id: UUID(1), front: "chat", back: "cat", due: date, createdAt: date, updatedAt: date)
    let store = TestStore(initialState: loaded(cards)) {
      DeckFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.addCard = { _, _ in new }
    }

    await store.send(.addButtonTapped) {
      $0.destination = .editor(CardEditorFeature.State())
    }
    await store.send(\.destination.editor.binding.front, "chat") {
      $0.destination?.modify(\.editor) { $0.front = "chat" }
    }
    await store.send(\.destination.editor.binding.back, "cat") {
      $0.destination?.modify(\.editor) { $0.back = "cat" }
    }
    await store.send(\.destination.editor.saveButtonTapped) {
      $0.destination?.modify(\.editor) { $0.isSaving = true }
    }
    await store.receive(\.destination.editor.saveResponse.success)
    await store.receive(\.destination.editor.delegate.saved) {
      $0.cards.insert(new, at: 0)
    }
    await store.receive(\.delegate.deckChanged)
    await store.receive(\.destination.dismiss) {
      $0.destination = nil
    }
  }

  @Test func pullingReloadsWithTheQueryKeepingRowsUntilTheResponse() async {
    let queries = LockIsolated<[String?]>([])
    var state = loaded(cards)
    state.query = "ser"
    let store = TestStore(initialState: state) {
      DeckFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.cards = { query in
        queries.withValue { $0.append(query) }
        return [cards[0]]
      }
    }

    // No delegate and no query change: exhaustivity fails the test on either.
    await store.send(.pulledToRefresh)
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[0]]
    }
    #expect(queries.value == ["ser"])
  }

  @Test func onlyBecomingActiveReloadsWithTheQuery() async {
    let queries = LockIsolated<[String?]>([])
    var state = loaded([cards[0]])
    state.query = "ser"
    let store = TestStore(initialState: state) {
      DeckFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.cards = { query in
        queries.withValue { $0.append(query) }
        return cards
      }
    }

    await store.send(.scenePhaseChanged(.inactive))
    await store.send(.scenePhaseChanged(.background))
    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.success) {
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
    }
    #expect(queries.value == ["ser"])
  }

  private func loaded(_ cards: [Card]) -> DeckFeature.State {
    var state = DeckFeature.State()
    state.cards = IdentifiedArray(uniqueElements: cards)
    state.phase = .loaded
    return state
  }
}
