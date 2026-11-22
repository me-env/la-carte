@testable import APIClient
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
      $0.apiClient.isConfigured = { true }
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
      $0.apiClient.isConfigured = { true }
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
      $0.continuousClock = TestClock()
      $0.date = .constant(nextDue)
      $0.apiClient.isConfigured = { true }
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
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func ratingTheLastCardPicksUpCardsBeyondTheLimit() async {
    var state = studying([cards[0]])
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
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

  @Test func emptyDeckShowsTheEmptyState() async {
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in [] }
      $0.apiClient.stats = { DeckStats(total: 0, due: 0, new: 0, reviewedToday: 0, nextDue: nil) }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.success) {
      $0.phase = .empty
    }
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func nextDueText() {
    #expect(StudyView.nextDueText(Date.now.addingTimeInterval(23 * 3600 + 60)) == "Next card in 23 hours")
  }

  @Test func dueCardsFailureShowsOffline() async {
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in throw Offline() }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.failure) {
      $0.phase = .offline
    }
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func statsFailureShowsOffline() async {
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in [] }
      $0.apiClient.stats = { throw Offline() }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.failure) {
      $0.phase = .offline
    }
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func reviewFailureShowsOffline() async {
    var state = studying(cards)
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.apiClient.isConfigured = { true }
      $0.apiClient.review = { _, _ in throw Offline() }
    }

    await store.send(.ratingTapped(.again)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.failure) {
      $0.isReviewing = false
      $0.phase = .offline
    }
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func ratingIsIgnoredWhileAReviewIsInFlight() async {
    let (responses, respond) = AsyncStream.makeStream(of: Card.self)
    let reviewCount = LockIsolated(0)
    var state = studying(cards)
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
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
      $0.continuousClock = TestClock()
      $0.apiClient.isConfigured = { true }
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
      $0.apiClient.isConfigured = { true }
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
      $0.apiClient.isConfigured = { true }
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
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in [cards[1], cards[2]] }
    }

    await store.send(.deckChanged)
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[1], self.cards[2]]
      $0.isRevealed = false
    }
  }

  @Test func becomingActiveWhenCaughtUpShowsANewCardWithoutLoading() async {
    var state = StudyFeature.State()
    state.phase = .caughtUp(nextDue: nil)
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in [cards[0]] }
    }

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[0]]
      $0.phase = .studying
    }
  }

  @Test func refreshKeepsTheRevealWhenTheFirstCardIsUnchanged() async {
    var state = studying([cards[0]])
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in [cards[0], cards[1]] }
    }

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[0], self.cards[1]]
    }
  }

  @Test func refreshResetsTheRevealWhenTheFirstCardChanged() async {
    var state = studying(cards)
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in [cards[1], cards[2]] }
    }

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[1], self.cards[2]]
      $0.isRevealed = false
    }
  }

  @Test func refreshIsIgnoredWhileARatingIsInFlight() async {
    var state = studying(cards)
    state.isRevealed = true
    state.isReviewing = true
    // `dueCards` is unimplemented: calling it fails the test.
    let store = TestStore(initialState: state) { StudyFeature() }

    await store.send(.scenePhaseChanged(.active))
  }

  @Test func onlyBecomingActiveReloads() async {
    let store = TestStore(initialState: studying(cards)) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in cards }
    }

    await store.send(.scenePhaseChanged(.inactive))
    await store.send(.scenePhaseChanged(.background))
    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.success)
  }

  @Test func aNewLoadCancelsTheOneInFlight() async {
    let loads = LockIsolated(0)
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      // Only cancellation ends the first load: if the refresh didn't cancel it, the store would finish with it in flight.
      $0.apiClient.dueCards = { _ in
        let load = loads.withValue { $0 += 1; return $0 }
        if load == 1 { try await Task.never() }
        return [cards[1]]
      }
    }

    await store.send(.onAppear)
    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[1]]
      $0.phase = .studying
    }
    #expect(loads.value == 2)
  }

  @Test func ratingCancelsALoadInFlightSoTheRatedCardCantComeBack() async {
    let store = TestStore(initialState: studying(cards)) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      // Only cancellation ends this load: if rating didn't cancel it, the store would finish with it in flight.
      $0.apiClient.dueCards = { _ in
        try await Task.never()
      }
      $0.apiClient.review = { _, _ in cards[0] }
    }

    await store.send(.scenePhaseChanged(.active))
    await store.send(.revealTapped) {
      $0.isRevealed = true
    }
    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
  }

  @Test func withoutAServerOrTokenAppearingAsksToConnectWithoutARequest() async {
    // `dueCards` and `stats` are unimplemented: calling either fails the test.
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { false }
    }

    await store.send(.onAppear) {
      $0.phase = .notSetUp
    }
  }

  @Test func losingTheSetupClearsTheCards() async {
    var state = studying(cards)
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { false }
    }

    await store.send(.deckChanged) {
      $0.cards = []
      $0.isRevealed = false
      $0.phase = .notSetUp
    }
  }

  @Test func becomingActiveWhenNotSetUpChecksAgainAndLoadsOnceConfigured() async {
    let configured = LockIsolated(false)
    var state = StudyFeature.State()
    state.phase = .notSetUp
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { configured.value }
      $0.apiClient.dueCards = { _ in cards }
    }

    await store.send(.scenePhaseChanged(.active))
    configured.setValue(true)
    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.success) {
      $0.cards = IdentifiedArray(uniqueElements: self.cards)
      $0.phase = .studying
    }
  }

  @Test func openSettingsAsksTheParent() async {
    let store = TestStore(initialState: StudyFeature.State()) { StudyFeature() }

    await store.send(.openSettingsTapped)
    await store.receive(\.delegate.settingsRequested)
  }

  @Test func aRejectedTokenSaysSoInsteadOfOffline() async {
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in throw APIError(statusCode: 401, message: "Unauthorized") }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.failure) {
      $0.phase = .unauthorized
    }
  }

  @Test func aRejectedStatsCallSaysTokenRejected() async {
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in [] }
      $0.apiClient.stats = { throw APIError(statusCode: 401, message: "Unauthorized") }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.success)
    await store.receive(\.statsResponse.failure) {
      $0.phase = .unauthorized
    }
  }

  @Test func aForbiddenReviewSaysTokenRejected() async {
    var state = studying(cards)
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.review = { _, _ in throw APIError(statusCode: 403, message: "Forbidden") }
    }

    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.failure) {
      $0.isReviewing = false
      $0.phase = .unauthorized
    }
  }

  @Test func aServerErrorIsStillOffline() async {
    let store = TestStore(initialState: StudyFeature.State()) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in throw APIError(statusCode: 500, message: "Internal Server Error") }
    }

    await store.send(.onAppear)
    await store.receive(\.cardsResponse.failure) {
      $0.phase = .offline
    }
    await store.send(.scenePhaseChanged(.background))
  }

  // MARK: Inline edit (spec 010)

  @Test func tappingAnUnrevealedCardRevealsWithoutEditing() async {
    let store = TestStore(initialState: studying(cards)) { StudyFeature() }

    await store.send(.textDoubleTapped(.front))
    await store.send(.cardTapped) {
      $0.isRevealed = true
    }
    await store.send(.cardTapped)
  }

  @Test func doubleTappingARevealedSideEditsItOneAtATime() async {
    let store = TestStore(initialState: revealed(cards)) { StudyFeature() }

    await store.send(.textDoubleTapped(.front)) {
      $0.editing = .front
      $0.draft = "serendipity"
    }
    await store.send(.textDoubleTapped(.back))
    await store.send(.editEnded) {
      $0.editing = nil
    }
    await store.send(.textDoubleTapped(.back)) {
      $0.editing = .back
      $0.draft = "finding something good without looking for it"
    }
  }

  @Test func doneSavesTheEditOptimistically() async {
    let updates = LockIsolated<[(Card.ID, String, String)]>([])
    let (responses, respond) = AsyncStream.makeStream(of: Card.self)
    var saved = cards[0]
    saved.setText("a happy accident", for: .back)
    let store = TestStore(initialState: revealed(cards)) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.updateCard = { id, front, back in
        updates.withValue { $0.append((id, front, back)) }
        for await card in responses { return card }
        throw CancellationError()
      }
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
    respond.yield(saved)
    await store.receive(\.editSaveResponse) {
      $0.isSavingEdit = false
    }
    #expect(updates.value.map(\.0) == [cards[0].id])
    #expect(updates.value.map(\.1) == ["serendipity"])
    #expect(updates.value.map(\.2) == ["a happy accident"])
  }

  @Test func returnTypedAtTheEndOfTheFieldEndsTheEdit() async {
    var state = revealed(cards)
    state.editing = .back
    state.draft = "a happy accident"
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.updateCard = { _, _, back in
        var card = cards[0]
        card.setText(back, for: .back)
        return card
      }
    }

    await store.send(.draftChanged("a happy accident\n")) {
      $0.draft = "a happy accident"
      $0.editing = nil
      $0.cards[0].setText("a happy accident", for: .back)
      $0.isSavingEdit = true
    }
    await store.receive(\.editSaveResponse) {
      $0.isSavingEdit = false
    }
  }

  @Test func aNewlineTypedMidTextEndsTheEditAndIsDropped() async {
    var state = revealed(cards)
    state.editing = .back
    state.draft = "a happy accident"
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.updateCard = { _, _, back in
        var card = cards[0]
        card.setText(back, for: .back)
        return card
      }
    }

    await store.send(.draftChanged("a happy\n accident")) {
      $0.draft = "a happy accident"
      $0.editing = nil
      $0.cards[0].setText("a happy accident", for: .back)
      $0.isSavingEdit = true
    }
    await store.receive(\.editSaveResponse) {
      $0.isSavingEdit = false
    }
  }

  @Test func theCardsOwnNewlinesAreNotTyped() {
    #expect(StudyFeature.droppingTypedNewlines(old: "one\ntwo", new: "one\ntwos") == nil)
    #expect(StudyFeature.droppingTypedNewlines(old: "one\ntwo", new: "one\nt\nwo") == "one\ntwo")
    #expect(StudyFeature.droppingTypedNewlines(old: "ab", new: "a\nb") == "ab")
  }

  @Test func addingOrOpeningTheDeckWhileEditingCommitsFirst() async {
    let updates = LockIsolated(0)
    var state = revealed(cards)
    state.editing = .back
    state.draft = "a happy accident"
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.updateCard = { _, _, back in
        updates.withValue { $0 += 1 }
        var card = cards[0]
        card.setText(back, for: .back)
        return card
      }
    }

    await store.send(.addButtonTapped) {
      $0.editing = nil
      $0.cards[0].setText("a happy accident", for: .back)
      $0.isSavingEdit = true
    }
    await store.receive(\.delegate.addCardRequested)
    await store.receive(\.editSaveResponse) {
      $0.isSavingEdit = false
    }
    await store.send(.deckButtonTapped)
    await store.receive(\.delegate.deckRequested)
    #expect(updates.value == 1)
  }

  @Test func tappingTheCardWhileEditingLeavesTheEditToFocus() async {
    var state = revealed(cards)
    state.editing = .front
    state.draft = "serendipitous"
    let store = TestStore(initialState: state) { StudyFeature() }

    // The view drops focus on a tap outside the field; that focus loss alone ends the edit (`editEnded`).
    await store.send(.cardTapped)
  }

  @Test func anUnchangedOrBlankEditSendsNothing() async {
    // `updateCard` is unimplemented: calling it fails the test.
    let store = TestStore(initialState: revealed(cards)) { StudyFeature() }

    await store.send(.textDoubleTapped(.front)) {
      $0.editing = .front
      $0.draft = "serendipity"
    }
    await store.send(.draftChanged(" serendipity ")) {
      $0.draft = " serendipity "
    }
    await store.send(.editEnded) {
      $0.editing = nil
    }
    await store.send(.textDoubleTapped(.back)) {
      $0.editing = .back
      $0.draft = "finding something good without looking for it"
    }
    await store.send(.draftChanged("  \n ")) {
      $0.draft = "   "
      $0.editing = nil
    }
  }

  @Test func theSavedTextIsTrimmed() async {
    let sent = LockIsolated<String?>(nil)
    var state = revealed(cards)
    state.editing = .back
    state.draft = "  a happy accident \n"
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.updateCard = { _, _, back in
        sent.setValue(back)
        var card = cards[0]
        card.setText(back, for: .back)
        return card
      }
    }

    await store.send(.editEnded) {
      $0.editing = nil
      $0.cards[0].setText("a happy accident", for: .back)
      $0.isSavingEdit = true
    }
    await store.receive(\.editSaveResponse) {
      $0.isSavingEdit = false
    }
    #expect(sent.value == "a happy accident")
  }

  @Test func aFailedSaveRestoresTheTextAndSaysSoUntilTheNextEditOrRating() async {
    var state = revealed(cards)
    state.editing = .back
    state.draft = "a happy accident"
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.updateCard = { _, _, _ in throw APIError(statusCode: 500, message: "Internal Server Error") }
      $0.apiClient.review = { _, _ in cards[0] }
    }

    await store.send(.editEnded) {
      $0.editing = nil
      $0.cards[0].setText("a happy accident", for: .back)
      $0.isSavingEdit = true
    }
    await store.receive(\.editSaveResponse) {
      $0.isSavingEdit = false
      $0.cards[0] = self.cards[0]
      $0.editFailed = true
    }
    await store.send(.textDoubleTapped(.front)) {
      $0.editing = .front
      $0.draft = "serendipity"
      $0.editFailed = false
    }
    await store.send(.draftChanged("serendipitous")) {
      $0.draft = "serendipitous"
    }
    await store.send(.editEnded) {
      $0.editing = nil
      $0.cards[0].setText("serendipitous", for: .front)
      $0.isSavingEdit = true
    }
    await store.receive(\.editSaveResponse) {
      $0.isSavingEdit = false
      $0.cards[0].setText("serendipity", for: .front)
      $0.editFailed = true
    }
    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
      $0.editFailed = false
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
  }

  @Test func refreshIsSkippedWhileEditing() async {
    var state = revealed(cards)
    state.editing = .back
    // `dueCards` is unimplemented: calling it fails the test.
    let store = TestStore(initialState: state) { StudyFeature() }

    await store.send(.scenePhaseChanged(.active))
  }

  @Test func startingAnEditCancelsALoadInFlight() async {
    let store = TestStore(initialState: revealed(cards)) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      // Only cancellation ends this load: if the edit didn't cancel it, the store would finish with it in flight.
      $0.apiClient.dueCards = { _ in try await Task.never() }
    }

    await store.send(.scenePhaseChanged(.active))
    await store.send(.textDoubleTapped(.back)) {
      $0.editing = .back
      $0.draft = "finding something good without looking for it"
    }
  }

  @Test func whileASaveIsInFlightNoEditStartsAndRefreshIsSkipped() async {
    let (responses, respond) = AsyncStream.makeStream(of: Card.self)
    var state = revealed(cards)
    state.editing = .back
    state.draft = "a happy accident"
    // `dueCards` is unimplemented: calling it fails the test.
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.updateCard = { _, _, _ in
        for await card in responses { return card }
        throw CancellationError()
      }
    }

    await store.send(.editEnded) {
      $0.editing = nil
      $0.cards[0].setText("a happy accident", for: .back)
      $0.isSavingEdit = true
    }
    await store.send(.textDoubleTapped(.front))
    await store.send(.scenePhaseChanged(.active))
    var saved = cards[0]
    saved.setText("a happy accident", for: .back)
    respond.yield(saved)
    await store.receive(\.editSaveResponse) {
      $0.isSavingEdit = false
    }
    #expect(store.state.isRevealed)
  }

  @Test func aSaveResponseForARatedCardChangesNothing() async {
    let (saves, respondToSave) = AsyncStream.makeStream(of: Card.self)
    var state = revealed(cards)
    state.editing = .back
    state.draft = "a happy accident"
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.updateCard = { _, _, _ in
        for await card in saves { return card }
        throw CancellationError()
      }
      $0.apiClient.review = { _, _ in cards[0] }
    }

    await store.send(.editEnded) {
      $0.editing = nil
      $0.cards[0].setText("a happy accident", for: .back)
      $0.isSavingEdit = true
    }
    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
    var saved = cards[0]
    saved.setText("a happy accident", for: .back)
    respondToSave.yield(saved)
    await store.receive(\.editSaveResponse) {
      $0.isSavingEdit = false
    }
  }

  // MARK: Ratings (spec 011)

  @Test func forgotAndGotItSendAgainAndGood() async {
    for rating in [Rating.again, .good] {
      let reviewed = LockIsolated<[Rating]>([])
      let store = TestStore(initialState: revealed(cards)) {
        StudyFeature()
      } withDependencies: { [cards] in
        $0.apiClient.review = { _, rating in
          reviewed.withValue { $0.append(rating) }
          return cards[0]
        }
      }

      await store.send(.ratingTapped(rating)) {
        $0.isReviewing = true
      }
      await store.receive(\.reviewResponse.success) {
        $0.isReviewing = false
        $0.isRevealed = false
        $0.cards.removeFirst()
      }
      #expect(reviewed.value == [rating])
    }
  }

  @Test func easeIsTheSwipeOverTheRingClamped() {
    let expected: [(Double, Double)] = [(-0.6, 0), (-0.25, 0), (-0.1, 0.3), (0, 0.5), (0.1, 0.7), (0.25, 1), (0.6, 1)]
    for (fraction, ease) in expected {
      #expect(abs(StudyFeature.ease(forSwipe: fraction) - ease) < 1e-9, "f = \(fraction)")
    }
  }

  @Test func easeIsQuantizedIntoFourGradesAndADeadZone() {
    let expected: [(Double, Rating?)] = [
      (0, .again), (0.125, .again), (0.126, .hard), (0.35, .hard), (0.351, nil), (0.5, nil), (0.649, nil),
      (0.65, .good), (0.874, .good), (0.875, .easy), (1, .easy),
    ]
    for (ease, rating) in expected {
      #expect(StudyFeature.rating(forEase: ease) == rating, "v = \(ease)")
    }
  }

  @Test func draggingFollowsTheFingerWithTheGradeItWouldSend() async {
    let store = TestStore(initialState: revealed(cards)) { StudyFeature() }

    await store.send(.swipeChanged(fraction: 0.13)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: 0.13)
    }
    #expect(store.state.swipeRating == .good)
    await store.send(.swipeChanged(fraction: 0.22)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: 0.22)
    }
    #expect(store.state.swipeRating == .easy)
    await store.send(.swipeChanged(fraction: -0.13)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: -0.13)
    }
    #expect(store.state.swipeRating == .hard)
    await store.send(.swipeChanged(fraction: -0.22)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: -0.22)
    }
    #expect(store.state.swipeRating == .again)
    await store.send(.swipeChanged(fraction: 0.04)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: 0.04)
    }
    #expect(store.state.swipeRating == nil)
  }

  @Test(arguments: [(0.13, Rating.good), (0.22, .easy), (-0.13, .hard), (-0.22, .again)])
  func releasingReviewsWithTheQuantizedGrade(fraction: Double, rating: Rating) async {
    let reviewed = LockIsolated<[(Card.ID, Rating)]>([])
    let store = TestStore(initialState: revealed(cards)) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.review = { id, rating in
        reviewed.withValue { $0.append((id, rating)) }
        return cards[0]
      }
    }

    await store.send(.swipeChanged(fraction: fraction)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: fraction)
    }
    await store.send(.swipeEnded(fraction: fraction)) {
      $0.swipeEase = nil
      $0.isReviewing = true
      $0.releasedRating = rating
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.releasedRating = nil
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
    #expect(reviewed.value.map(\.0) == [cards[0].id])
    #expect(reviewed.value.map(\.1) == [rating])
  }

  @Test func releasingInTheDeadZoneOrBackAtTheStartSendsNothing() async {
    let store = TestStore(initialState: revealed(cards)) { StudyFeature() }

    await store.send(.swipeChanged(fraction: 0.04)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: 0.04)
    }
    await store.send(.swipeEnded(fraction: 0.04)) {
      $0.swipeEase = nil
    }
    await store.send(.swipeChanged(fraction: 0.22)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: 0.22)
    }
    await store.send(.swipeChanged(fraction: 0)) {
      $0.swipeEase = 0.5
    }
    await store.send(.swipeEnded(fraction: 0)) {
      $0.swipeEase = nil
    }
  }

  @Test func draggingAnUnrevealedCardDoesNothing() async {
    let store = TestStore(initialState: studying(cards)) { StudyFeature() }

    await store.send(.swipeChanged(fraction: 0.22))
    await store.send(.swipeEnded(fraction: 0.22))
  }

  @Test func draggingWhileEditingDoesNothing() async {
    var state = revealed(cards)
    state.editing = .back
    state.draft = cards[0].back
    let store = TestStore(initialState: state) { StudyFeature() }

    await store.send(.swipeChanged(fraction: 0.22))
    await store.send(.swipeEnded(fraction: 0.22))
  }

  @Test func draggingWhileAReviewIsInFlightDoesNothing() async {
    var state = revealed(cards)
    state.isReviewing = true
    let store = TestStore(initialState: state) { StudyFeature() }

    await store.send(.swipeChanged(fraction: -0.22))
    await store.send(.swipeEnded(fraction: -0.22))
  }

  @Test func aFailedDragReviewRetriesToTheSameRevealedCardWithoutARing() async {
    let store = TestStore(initialState: revealed(cards)) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.continuousClock = TestClock()
      $0.apiClient.isConfigured = { true }
      $0.apiClient.review = { _, _ in throw Offline() }
      $0.apiClient.dueCards = { _ in cards }
    }

    await store.send(.swipeChanged(fraction: 0.13)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: 0.13)
    }
    await store.send(.swipeEnded(fraction: 0.13)) {
      $0.swipeEase = nil
      $0.isReviewing = true
      $0.releasedRating = .good
    }
    await store.receive(\.reviewResponse.failure) {
      $0.isReviewing = false
      $0.releasedRating = nil
      $0.phase = .offline
    }
    await store.send(.retryButtonTapped) {
      $0.phase = .loading
    }
    await store.receive(\.cardsResponse.success) {
      $0.phase = .studying
    }
    #expect(store.state.isRevealed && store.state.swipeEase == nil)
  }

  @Test func aRefreshWithANewFirstCardClearsTheRing() async {
    var state = revealed(cards)
    state.swipeEase = 0.76
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in [cards[1], cards[2]] }
    }

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[1], self.cards[2]]
      $0.isRevealed = false
      $0.swipeEase = nil
    }
  }

  @Test func aRefreshWithTheSameFirstCardKeepsTheRing() async {
    var state = revealed(cards)
    state.swipeEase = 0.76
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in [cards[0], cards[2]] }
    }

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.success) {
      $0.cards = [self.cards[0], self.cards[2]]
    }
  }

  @Test func aLoadFailingMidDragClearsTheRing() async {
    var state = revealed(cards)
    state.swipeEase = 0.76
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in throw Offline() }
    }

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.cardsResponse.failure) {
      $0.phase = .offline
      $0.swipeEase = nil
    }
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func aReleaseAfterTheDragLostItsCardClearsTheRingWithoutAReview() async {
    var state = revealed(cards)
    state.swipeEase = 1
    state.phase = .offline
    let store = TestStore(initialState: state) { StudyFeature() }

    await store.send(.swipeEnded(fraction: 0.22)) {
      $0.swipeEase = nil
    }
  }

  private func revealed(_ cards: [Card]) -> StudyFeature.State {
    var state = studying(cards)
    state.isRevealed = true
    return state
  }

  private func studying(_ cards: [Card]) -> StudyFeature.State {
    var state = StudyFeature.State()
    state.cards = IdentifiedArray(uniqueElements: cards)
    state.phase = .studying
    return state
  }
}
