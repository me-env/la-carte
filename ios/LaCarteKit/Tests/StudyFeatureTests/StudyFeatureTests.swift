import APIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import StudyFeature

@MainActor
struct StudyFeatureTests {
  let cards = [Card].fixtures
  struct Offline: Error {}

  @Test func appearLoadsDueCardsInOrder() async {
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.dueCards = { limit in
        #expect(limit == 100)
        return cards
      }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.success) {
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
      $0.phase = .studying
    }
  }

  @Test func tappingTheCardOrShowAnswerReveals() async {
    let store = TestStore(initialState: studying(cards)) { StudyFeature() }

    await store.send(.revealTapped) {
      $0.isRevealed = true
    }
    await store.send(.revealTapped)
  }

  @Test func ratingReviewsTheCardAndShowsTheNextOne() async {
    let reviewed = LockIsolated<[(Card.ID, Rating)]>([])
    var state = studying(cards)
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.review = { id, rating in
        reviewed.withValue { $0.append((id, rating)) }
        return cards[0]
      }
    }

    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
    #expect(reviewed.value.map(\.0) == [cards[0].id])
    #expect(reviewed.value.map(\.1) == [.good])
  }

  @Test func ratingTheLastCardShowsCaughtUpWithNextDue() async {
    let nextDue = Date(timeIntervalSince1970: 1_795_217_048)
    var state = studying([cards[0]])
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.review = { _, _ in cards[0] }
      $0.apiClient.dueCards = { _ in [] }
      $0.apiClient.stats = { DeckStats(total: 3, due: 0, new: 0, reviewedToday: 3, nextDue: nextDue) }
    }

    await store.send(.ratingTapped(.easy)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards = []
    }
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.success) {
      $0.phase = .caughtUp(nextDue: nextDue)
    }
  }

  @Test func ratingTheLastCardPicksUpCardsBeyondTheLimit() async {
    var state = studying([cards[0]])
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.review = { _, _ in cards[0] }
      $0.apiClient.dueCards = { _ in [cards[1]] }
    }

    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards = []
    }
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[1]]
    }
  }

  @Test func emptyDeckShowsCaughtUpWithoutNextDue() async {
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.dueCards = { _ in [] }
      $0.apiClient.stats = { DeckStats(total: 0, due: 0, new: 0, reviewedToday: 0, nextDue: nil) }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.success) {
      $0.phase = .caughtUp(nextDue: nil)
    }
  }

  @Test func nextDueText() {
    #expect(StudyView.nextDueText(nil) == "Your deck is empty")
    #expect(StudyView.nextDueText(Date.now.addingTimeInterval(23 * 3600 + 60)) == "Next card in 23 hours")
  }

  @Test func dueCardsFailureShowsOffline() async {
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.dueCards = { _ in throw Offline() }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.failure) {
      $0.phase = .offline
    }
  }

  @Test func statsFailureShowsOffline() async {
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.dueCards = { _ in [] }
      $0.apiClient.stats = { throw Offline() }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.failure) {
      $0.phase = .offline
    }
  }

  @Test func reviewFailureShowsOffline() async {
    var state = studying(cards)
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.review = { _, _ in throw Offline() }
    }

    await store.send(.ratingTapped(.again)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.failure) {
      $0.isReviewing = false
      $0.phase = .offline
    }
  }

  @Test func ratingIsIgnoredWhileAReviewIsInFlight() async {
    let (responses, respond) = AsyncStream.makeStream(of: Card.self)
    let reviewCount = LockIsolated(0)
    var state = studying(cards)
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.review = { _, _ in
        reviewCount.withValue { $0 += 1 }
        for await card in responses { return card }
        throw CancellationError()
      }
    }

    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
    }
    await store.send(.ratingTapped(.easy))
    respond.yield(cards[0])
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
    #expect(reviewCount.value == 1)
  }

  @Test func retryAfterAFailedReviewKeepsTheCardRevealed() async {
    var state = studying(cards)
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.review = { _, _ in throw Offline() }
      $0.apiClient.dueCards = { _ in cards }
    }

    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.failure) {
      $0.isReviewing = false
      $0.phase = .offline
    }
    await store.send(.retryButtonTapped) {
      $0.phase = .loading
    }
    await store.receive(\.cardsResponse.success) {
      $0.phase = .studying
    }
  }

  @Test func retryReloadsDueCards() async {
    var state = StudyFeature.State()
    state.phase = .offline
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.dueCards = { _ in cards }
    }

    await store.send(.retryButtonTapped) {
      $0.phase = .loading
    }
    await store.receive(\.cardsResponse.success) {
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
      $0.phase = .studying
    }
  }

  @Test func deckAndAddButtonsAskTheParent() async {
    let store = TestStore(initialState: StudyFeature.State()) { StudyFeature() }

    await store.send(.deckButtonTapped)
    await store.receive(\.delegate.deckRequested)
    await store.send(.addButtonTapped)
    await store.receive(\.delegate.addCardRequested)
  }

  @Test func deckChangedKeepsTheRevealWhenTheCurrentCardIsUnchanged() async {
    var state = studying(cards)
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.dueCards = { _ in [cards[0], cards[2]] }
    }

    await store.send(.deckChanged)
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[0], self.cards[2]]
    }
  }

  @Test func deckChangedResetsTheRevealWhenTheCurrentCardChanged() async {
    var state = studying(cards)
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.dueCards = { _ in [cards[1], cards[2]] }
    }

    await store.send(.deckChanged)
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[1], self.cards[2]]
      $0.isRevealed = false
    }
  }

  private func studying(_ cards: [Card]) -> StudyFeature.State {
    var state = StudyFeature.State()
    state.cards = IdentifiedArray(uniqueElements: cards)
    state.phase = .studying
    return state
  }
}
