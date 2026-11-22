@testable import APIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import StudyFeature

/// Spec 018: Study reloads by itself when the next card is due and every 30 s while there is nothing to study.
@MainActor
struct StudyAutoRefreshTests {
  let cards = [Card].fixtures
  let now = Date(timeIntervalSince1970: 1_767_225_600)
  struct Offline: Error {}

  @Test func theNextCardShowsTheMomentItIsDue() async {
    let clock = TestClock()
    let loads = LockIsolated(0)
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: { [cards, now] in
      $0.continuousClock = clock
      $0.date = .constant(now)
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in
        loads.withValue { $0 += 1; return $0 } == 1 ? [] : [cards[0]]
      }
      $0.apiClient.stats = { Self.stats(nextDue: now.addingTimeInterval(10)) }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.success) {
      $0.phase = .caughtUp(nextDue: self.now.addingTimeInterval(10))
    }
    await clock.advance(by: .milliseconds(9_900))
    #expect(loads.value == 1)
    await clock.advance(by: .milliseconds(100))
    await store.receive(\.autoRefreshFired)
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[0]]
      $0.phase = .studying
    }
    #expect(loads.value == 2)
  }

  @Test(arguments: [
    StudyAutoRefreshTests.stats(nextDue: nil),
    StudyAutoRefreshTests.stats(nextDue: Date(timeIntervalSince1970: 1_767_225_600 + 3600)),
    DeckStats(total: 0, due: 0, new: 0, reviewedToday: 0, nextDue: nil),
  ])
  func withNothingToStudyItChecksEvery30Seconds(stats: DeckStats) async {
    let clock = TestClock()
    let loads = LockIsolated(0)
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: { [now] in
      $0.continuousClock = clock
      $0.date = .constant(now)
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in
        loads.withValue { $0 += 1 }
        return []
      }
      $0.apiClient.stats = { stats }
    }
    let phase: StudyFeature.State.Phase = stats.total == 0 ? .empty : .caughtUp(nextDue: stats.nextDue)

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.success) {
      $0.phase = phase
    }
    for check in 1...3 {
      await clock.advance(by: .milliseconds(29_900))
      #expect(loads.value == check)
      await clock.advance(by: .milliseconds(100))
      await store.receive(\.autoRefreshFired)
      await store.receive(\.cardsResponse.success)
      await store.receive(\.statsResponse.success)
    }
    #expect(loads.value == 1 + 3)
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func aNextDueInThePastWaitsOneSecondNotZero() async {
    let clock = TestClock()
    let loads = LockIsolated(0)
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: { [now] in
      $0.continuousClock = clock
      $0.date = .constant(now)
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in
        loads.withValue { $0 += 1 }
        return []
      }
      $0.apiClient.stats = { Self.stats(nextDue: now.addingTimeInterval(-5)) }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.success) {
      $0.phase = .caughtUp(nextDue: self.now.addingTimeInterval(-5))
    }
    await clock.advance(by: .milliseconds(900))
    #expect(loads.value == 1)
    await clock.advance(by: .milliseconds(100))
    await store.receive(\.autoRefreshFired)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.success)
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func offlineRetriesQuietlyEvery30SecondsUntilAResponse() async {
    let clock = TestClock()
    let loads = LockIsolated(0)
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.continuousClock = clock
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in
        guard loads.withValue({ $0 += 1; return $0 }) == 3 else { throw Offline() }
        return cards
      }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.failure) {
      $0.phase = .offline
    }
    await clock.advance(by: .seconds(30))
    await store.receive(\.autoRefreshFired)
    await store.receive(\.cardsResponse.failure)
    await clock.advance(by: .seconds(30))
    await store.receive(\.autoRefreshFired)
    await store.receive(\.cardsResponse.success) {
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
      $0.phase = .studying
    }
    await clock.advance(by: .seconds(300))
    #expect(loads.value == 3)
  }

  @Test func retryStillShowsLoadingAndStopsTheTimerWhileItLoads() async {
    let clock = TestClock()
    let (responses, respond) = AsyncStream.makeStream(of: [Card].self)
    let loads = LockIsolated(0)
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in
        guard loads.withValue({ $0 += 1; return $0 }) > 1 else { throw Offline() }
        for await cards in responses { return cards }
        throw CancellationError()
      }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.failure) {
      $0.phase = .offline
    }
    await store.send(.retryButtonTapped) {
      $0.phase = .loading
    }
    await clock.advance(by: .seconds(300))
    respond.yield(cards)
    await store.receive(\.cardsResponse.success) {
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
      $0.phase = .studying
    }
    #expect(loads.value == 2)
  }

  @Test func noTimerWhileStudyingNotSetUpOrUnauthorized() async {
    let clock = TestClock()
    let configured = LockIsolated(true)
    let response = LockIsolated<Result<[Card], any Error>>(.success([]))
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.apiClient.isConfigured = { configured.value }
      $0.apiClient.dueCards = { _ in try response.value.get() }
      $0.apiClient.stats = { Self.stats(nextDue: nil) }
    }

    // Caught up, then a card arrives: `.studying` cancels the armed timer.
    await store.send(.onAppear)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.success) {
      $0.phase = .caughtUp(nextDue: nil)
    }
    response.setValue(.success([cards[0]]))
    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[0]]
      $0.phase = .studying
    }
    await clock.advance(by: .seconds(300))

    response.setValue(.failure(APIError(statusCode: 403, message: "Forbidden")))
    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.failure) {
      $0.phase = .unauthorized
    }
    await clock.advance(by: .seconds(300))

    configured.setValue(false)
    await store.send(.deckChanged) {
      $0.cards = []
      $0.phase = .notSetUp
    }
    await clock.advance(by: .seconds(300))
  }

  @Test func backgroundStopsTheTimerAndBecomingActiveRearmsIt() async {
    let clock = TestClock()
    let loads = LockIsolated(0)
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in
        loads.withValue { $0 += 1 }
        return []
      }
      $0.apiClient.stats = { Self.stats(nextDue: nil) }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.success) {
      $0.phase = .caughtUp(nextDue: nil)
    }
    await store.send(.scenePhaseChanged(.inactive))
    await clock.advance(by: .seconds(30))
    await store.receive(\.autoRefreshFired)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.success)

    await store.send(.scenePhaseChanged(.background))
    await clock.advance(by: .seconds(300))
    #expect(loads.value == 2)

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.success)
    await clock.advance(by: .seconds(30))
    await store.receive(\.autoRefreshFired)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.success)
    #expect(loads.value == 4)
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func aQuietReloadKeepsTheVisibleCardFirstWhileTheServerStillServesIt() async {
    var state = StudyFeature.State()
    state.cards = [cards[0], cards[1]]
    state.phase = .studying
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in [cards[2], cards[1], cards[0]] }
    }

    await store.send(.deckChanged)
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[0], self.cards[2], self.cards[1]]
    }
  }

  /// An edit saved while offline: its response never re-arms, so the dropped timer must.
  @Test func aTimerFiringWhileAnEditSavesIsDroppedAndRearmed() async {
    let clock = TestClock()
    var state = StudyFeature.State()
    state.cards = [cards[0]]
    state.phase = .offline
    state.isSavingEdit = true
    // `dueCards` is unimplemented: calling it fails the test.
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(.autoRefreshFired)
    await clock.advance(by: .seconds(30))
    await store.receive(\.autoRefreshFired)
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func aTimerFiringWhileEditingIsDropped() async {
    let clock = TestClock()
    var state = StudyFeature.State()
    state.cards = [cards[0]]
    state.phase = .offline
    state.isRevealed = true
    state.editing = .back
    // `dueCards` is unimplemented: calling it fails the test.
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(.autoRefreshFired)
    await clock.advance(by: .seconds(30))
    await store.receive(\.autoRefreshFired)
    await store.send(.scenePhaseChanged(.background))
  }

  nonisolated static func stats(nextDue: Date?) -> DeckStats {
    DeckStats(total: 3, due: 0, new: 0, reviewedToday: 3, nextDue: nextDue)
  }
}
