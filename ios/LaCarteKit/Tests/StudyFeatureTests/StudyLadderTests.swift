@testable import APIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import StudyFeature

/// Spec 021 AC 17-19: one queue load fetches cards and stats together, ratings refresh the ladder, step notices.
@MainActor
struct StudyLadderTests {
  let cards = [Card].fixtures
  let nextDue = Date(timeIntervalSince1970: 1_795_217_048)
  struct Offline: Error {}

  func stats(reviews: (Int, Int) = (0, 0), newToday: Int = 0, dueNew: Int = 0, total: Int = 3) -> DeckStats {
    DeckStats(
      total: total, due: 3, new: 0, reviewedToday: 0, nextDue: nextDue, newToday: newToday, dueNew: dueNew,
      reviewsTotal: reviews.1, reviewsDone: reviews.0
    )
  }

  func studying(_ cards: [Card], ladder: DeckStats? = nil) -> StudyFeature.State {
    var state = StudyFeature.State()
    state.cards = IdentifiedArray(uniqueElements: cards)
    state.phase = .studying
    state.isRevealed = true
    state.ladder = ladder.map(Ladder.init)
    return state
  }

  @Test func aLoadFetchesCardsAndStatsConcurrently() async {
    let statsAsked = AsyncStream.makeStream(of: Void.self)
    let stats = stats(reviews: (1, 3))
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      // Cards answer only once stats was asked: a sequential load would never finish.
      $0.apiClient.dueCards = { _ in
        for await _ in statsAsked.stream { break }
        return cards
      }
      $0.apiClient.stats = {
        statsAsked.continuation.yield()
        return stats
      }
    }

    await store.send(.onAppear)
    await store.receive(\.queueResponse) {
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
      $0.phase = .studying
      $0.ladder = Ladder(stats: stats)
    }
  }

  @Test func noCardsIsCaughtUpFromTheSameStats() async {
    let stats = stats()
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.date = .constant(nextDue)
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in [] }
      $0.apiClient.stats = { stats }
    }

    await store.send(.onAppear)
    await store.receive(\.queueResponse) {
      $0.phase = .caughtUp(nextDue: self.nextDue)
      $0.ladder = Ladder(stats: stats)
    }
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func failingStatsMakesTheLoadOffline() async {
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.continuousClock = TestClock()
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in cards }
      $0.apiClient.stats = { throw Offline() }
    }

    await store.send(.onAppear)
    await store.receive(\.queueResponse) {
      $0.phase = .offline
    }
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func aRatingRefreshesTheLadderAndShowsTheStepItCompleted() async {
    let clock = TestClock()
    let after = stats(reviews: (3, 3), dueNew: 1)
    let store = TestStore(initialState: studying(cards, ladder: stats(reviews: (2, 3), dueNew: 1))) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.continuousClock = clock
      $0.apiClient.review = { _, _ in cards[0] }
      $0.apiClient.stats = { after }
    }

    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
    await store.receive(\.ladderResponse) {
      $0.ladder = Ladder(stats: after)
      $0.notice = .stepDone("Reviews")
    }
    await clock.advance(by: StudyFeature.noticeDuration)
    await store.receive(\.noticeExpired) {
      $0.notice = nil
    }
  }

  @Test func aRatingThatCompletesNoStepShowsNoNotice() async {
    let after = stats(reviews: (2, 3))
    let store = TestStore(initialState: studying(cards, ladder: stats(reviews: (1, 3)))) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.review = { _, _ in cards[0] }
      $0.apiClient.stats = { after }
    }

    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
    await store.receive(\.ladderResponse) {
      $0.ladder = Ladder(stats: after)
    }
  }

  @Test func aFailedPostRatingFetchKeepsTheLadderAndThePhase() async {
    let before = stats(reviews: (1, 3))
    let store = TestStore(initialState: studying(cards, ladder: before)) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.review = { _, _ in cards[0] }
      $0.apiClient.stats = { throw Offline() }
    }

    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
    await store.receive(\.ladderResponse)
  }

  @Test func ratingTheLastCardLoadsTheQueueOnceAndShowsTheStep() async {
    let clock = TestClock()
    let after = stats(newToday: 15)
    let store = TestStore(initialState: studying([cards[0]], ladder: stats(newToday: 14, dueNew: 1))) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.continuousClock = clock
      $0.date = .constant(nextDue - 3600)  // the auto-refresh waits 30 s, past the notice
      $0.apiClient.isConfigured = { true }
      $0.apiClient.review = { _, _ in cards[0] }
      $0.apiClient.dueCards = { _ in [] }
      $0.apiClient.stats = { after }
    }

    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards = []
    }
    await store.receive(\.queueResponse) {
      $0.ladder = Ladder(stats: after)
      $0.notice = .stepDone("15 new")
      $0.phase = .caughtUp(nextDue: self.nextDue)
    }
    await clock.advance(by: StudyFeature.noticeDuration)
    await store.receive(\.noticeExpired) {
      $0.notice = nil
    }
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func aLoadNeverShowsAStepNotice() async {
    let after = stats(reviews: (3, 3), dueNew: 1)
    let store = TestStore(initialState: studying(cards, ladder: stats(reviews: (2, 3), dueNew: 1))) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in cards }
      $0.apiClient.stats = { after }
    }

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.queueResponse) {
      $0.ladder = Ladder(stats: after)
    }
  }

  @Test func aLoadCancelsAPendingRatingLadderSoItsOlderStatsNeverLand() async {
    let clock = TestClock()
    let stale = stats(reviews: (2, 3))
    let fresh = stats(reviews: (3, 3))
    let statsCalls = LockIsolated(0)
    let store = TestStore(initialState: studying(cards, ladder: stats(reviews: (1, 3)))) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.continuousClock = clock
      $0.apiClient.isConfigured = { true }
      $0.apiClient.review = { _, _ in cards[0] }
      $0.apiClient.dueCards = { _ in Array(cards.dropFirst()) }
      // The rating's ladder answers late; the load's stats right away.
      $0.apiClient.stats = { [clock] in
        let call = statsCalls.withValue { $0 += 1; return $0 }
        guard call == 1 else { return fresh }
        try await clock.sleep(for: .seconds(5))
        return stale
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
    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.queueResponse) {
      $0.ladder = Ladder(stats: fresh)
    }
    await clock.advance(by: .seconds(5))
  }

  @Test func tappingTheCounterOpensTheMilestonesOnceALadderIsLoaded() async {
    let noLadder = TestStore(initialState: studying(cards)) { StudyFeature() }
    await noLadder.send(.remainingTapped)

    let store = TestStore(initialState: studying(cards, ladder: stats(reviews: (1, 3)))) { StudyFeature() }
    await store.send(.remainingTapped) {
      $0.isMilestonesShown = true
    }
  }
}
