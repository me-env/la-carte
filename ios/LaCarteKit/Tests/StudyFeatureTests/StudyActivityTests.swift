import ActivityClient
@testable import APIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import StudyFeature

/// Spec 029 AC 21-26: what Study logs. State assertions are unchanged by logging (AC 29).
@MainActor
struct StudyActivityTests {
  let cards = [Card].fixtures
  let now = LockIsolated(Date(timeIntervalSince1970: 1_795_598_043))
  struct Offline: Error {}

  @Test func sceneActiveAndBackgroundLogTheAppState() async {
    let (store, logged) = makeStore { $0.apiClient.isConfigured = { false } }

    await store.send(.scenePhaseChanged(.active)) {
      $0.phase = .notSetUp
    }
    await store.send(.scenePhaseChanged(.background))
    await store.finish()
    #expect(logged.value == [.appForeground, .appBackground])
  }

  @Test func aQueueLogsItsCountsThenTheFirstCardOnce() async {
    let nextDue = Date(timeIntervalSince1970: 1_795_600_000)
    let stats = DeckStats(total: 9, due: 3, new: 2, reviewedToday: 0, nextDue: nextDue)
    let (store, logged) = makeStore { [cards] in
      $0.apiClient.dueCards = { _ in cards }
      $0.apiClient.stats = { stats }
    }

    await store.send(.onAppear)
    await store.receive(\.queueResponse) {
      $0.ladder = Ladder(stats: stats)
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
      $0.phase = .studying
    }
    await store.send(.deckChanged)
    await store.receive(\.queueResponse)
    await store.finish()

    let fetched = Activity.queueFetched(count: 3, due: 3, new: 2, total: 9, nextDue: nextDue)
    #expect(logged.value == [fetched, shown(cards[0]), fetched])
  }

  @Test func revealAndRatingLogTheirDurationsThenTheNextCard() async {
    let (store, logged) = makeStore { [cards] in
      $0.apiClient.dueCards = { _ in cards }
      $0.apiClient.stats = { .plain }
      $0.apiClient.review = { _, _ in cards[0] }
    }
    await load(store)

    now.withValue { $0 += 1.5 }
    await store.send(.revealTapped) {
      $0.isRevealed = true
    }
    await store.send(.cardTapped)
    now.withValue { $0 += 2 }
    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
    await store.receive(\.ladderResponse)
    await store.finish()

    #expect(
      logged.value.dropFirst(2) == [
        .answerRevealed(cardID: cards[0].id, msSinceShown: 1_500),
        .rated(cardID: cards[0].id, rating: .good, input: .button, msToReveal: 1_500, msToRate: 2_000),
        shown(cards[1]),
      ]
    )
  }

  @Test func aDragThatRatesLogsADragRatingAndOneThatDoesntLogsNothing() async {
    let (store, logged) = makeStore { [cards] in
      $0.apiClient.dueCards = { _ in cards }
      $0.apiClient.stats = { .plain }
      $0.apiClient.review = { _, _ in try await Task.never() }
    }
    await load(store)
    await store.send(.revealTapped) {
      $0.isRevealed = true
    }

    await store.send(.swipeChanged(fraction: 0.04)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: 0.04)
    }
    await store.send(.swipeEnded(fraction: 0.04)) {
      $0.swipeEase = nil
    }
    let review = await store.send(.swipeEnded(fraction: 0.24)) {
      $0.isReviewing = true
      $0.releasedRating = .easy
    }
    await review.cancel()
    await store.finish()

    #expect(
      logged.value.dropFirst(3) == [
        .rated(cardID: cards[0].id, rating: .easy, input: .drag, msToReveal: 0, msToRate: 0)
      ]
    )
  }

  @Test func aFailingReviewLogsTheRatingThenTheError() async {
    let (store, logged) = makeStore { [cards] in
      $0.apiClient.dueCards = { _ in cards }
      $0.apiClient.stats = { .plain }
      $0.apiClient.review = { _, _ in throw APIError(statusCode: 500, message: #"{"detail":"Internal error."}"#) }
      $0.continuousClock = TestClock()
    }
    await load(store)
    await store.send(.revealTapped) {
      $0.isRevealed = true
    }
    await store.send(.ratingTapped(.again)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.failure) {
      $0.isReviewing = false
      $0.phase = .offline
    }
    await store.skipInFlightEffects()

    #expect(
      logged.value.dropFirst(3) == [
        .rated(cardID: cards[0].id, rating: .again, input: .button, msToReveal: 0, msToRate: 0),
        .apiError(request: .review, cardID: cards[0].id, status: 500, error: "Internal error."),
      ]
    )
  }

  @Test func anOfflineQueueFetchLogsAnErrorWithoutStatus() async {
    let (store, logged) = makeStore {
      $0.apiClient.dueCards = { _ in throw URLError(.notConnectedToInternet) }
      $0.apiClient.stats = { .plain }
      $0.continuousClock = TestClock()
    }

    await store.send(.onAppear)
    await store.receive(\.queueResponse) {
      $0.phase = .offline
    }
    await store.skipInFlightEffects()

    #expect(logged.value == [.apiError(request: .queue, cardID: nil, status: 0, error: "notConnectedToInternet")])
  }

  @Test func aReportLogsItsReasonOnSuccess() async {
    let clock = TestClock()
    let (store, logged) = makeStore(revealed(cards)) {
      $0.apiClient.reportCard = { _, _, _ in }
      $0.apiClient.stats = { .plain }
      $0.continuousClock = clock
    }

    await store.send(.cardDoubleTapped) {
      $0.isReportMenuShown = true
    }
    await store.send(.reportReasonTapped(.wrong)) {
      $0.isReportMenuShown = false
      $0.isReviewing = true
    }
    await store.receive(\.reportResponse) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
      $0.notice = .reported
    }
    await store.receive(\.ladderResponse) {
      $0.ladder = Ladder(stats: .plain)
    }
    await clock.advance(by: .seconds(2))
    await store.receive(\.noticeExpired) {
      $0.notice = nil
    }

    #expect(logged.value == [shown(cards[0]), .reportSent(cardID: cards[0].id, reason: .wrong), shown(cards[1])])
  }

  @Test func aBrokenPhotoLogsTheSideThenTheReport() async {
    let (store, logged) = makeStore(revealed(cards)) {
      $0.apiClient.reportCard = { _, _, _ in }
      $0.apiClient.stats = { .plain }
    }

    await store.send(.photoLoadFailed(cardID: cards[0].id, url: "https://example.org/p.jpg", side: .back)) {
      $0.reportedBrokenPhotos = [self.cards[0].id]
    }
    await store.receive(\.brokenPhotoReportResponse)
    await store.receive(\.ladderResponse) {
      $0.ladder = Ladder(stats: .plain)
    }
    await store.finish()

    #expect(
      logged.value == [
        .photoFailed(cardID: cards[0].id, side: .back), shown(cards[0]),
        .reportSent(cardID: cards[0].id, reason: .brokenPhoto),
      ]
    )
  }

  @Test func anInlineEditLogsTheEditedNote() async {
    var saved = cards[0]
    saved.setText("a happy accident", for: .back)
    let (store, logged) = makeStore(revealed(cards)) { [saved] in
      $0.apiClient.updateCard = { _, _, _ in saved }
    }

    await store.send(.textDoubleTapped(.back)) {
      $0.editing = .back
      $0.draft = "finding something good without looking for it"
    }
    await store.send(.draftChanged("a happy accident")) {
      $0.draft = "a happy accident"
    }
    await store.send(.editEnded) {
      $0.editing = nil
      $0.cards[0].setText("a happy accident", for: .back)
      $0.isSavingEdit = true
    }
    await store.receive(\.editSaveResponse) {
      $0.isSavingEdit = false
    }
    await store.finish()

    #expect(
      logged.value == [shown(cards[0]), .noteEdited(noteID: cards[0].noteId, cardID: cards[0].id, source: .inline)]
    )
  }

  // MARK: Helpers

  private func makeStore(
    _ state: StudyFeature.State = StudyFeature.State(),
    _ dependencies: @escaping (inout DependencyValues) -> Void
  ) -> (TestStoreOf<StudyFeature>, LockIsolated<[Activity]>) {
    let (activity, logged) = ActivityClient.recording()
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [now] in
      $0.apiClient.isConfigured = { true }
      $0.activity = activity
      $0.activity.now = { now.value }
      dependencies(&$0)
    }
    return (store, logged)
  }

  /// Loads `cards` with `.plain` stats: logs `queue_fetched` and `card_shown`.
  private func load(_ store: TestStoreOf<StudyFeature>) async {
    await store.send(.onAppear)
    await store.receive(\.queueResponse) {
      $0.ladder = Ladder(stats: .plain)
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
      $0.phase = .studying
    }
  }

  private func shown(_ card: Card) -> Activity {
    .cardShown(cardID: card.id, noteID: card.noteId, type: card.type, prompt: card.prompt)
  }

  private func revealed(_ cards: [Card]) -> StudyFeature.State {
    var state = StudyFeature.State()
    state.cards = IdentifiedArray(uniqueElements: cards)
    state.phase = .studying
    state.isRevealed = true
    return state
  }
}
