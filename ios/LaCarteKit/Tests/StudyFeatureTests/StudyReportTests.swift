@testable import APIClient
import AskAIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import StudyFeature

/// Spec 015b (report a card, broken photos) and 016 (ask about this card: copy, open the picked app).
@MainActor
struct StudyReportTests {
  let cards = [Card].fixtures
  let person = [Note].fixtures[0]
  struct Offline: Error {}

  @Test func doubleTappingARevealedCardOpensTheMenu() async {
    let store = TestStore(initialState: revealed(cards)) { StudyFeature() }

    await store.send(.cardDoubleTapped) {
      $0.isReportMenuShown = true
    }
    await store.send(.binding(.set(\.isReportMenuShown, false))) {
      $0.isReportMenuShown = false
    }
  }

  /// The menu is a sheet: picking an item closes it, except Other…, whose comment alert sits on it until answered.
  @Test func pickingAnItemClosesTheMenu() async {
    var state = revealed(cards)
    state.isReportMenuShown = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.reportCard = { _, _, _ in try await Task.never() }
    }

    await store.send(.reportReasonTapped(.other)) {
      $0.isReportCommentShown = true
    }
    await store.send(.binding(.set(\.isReportCommentShown, false))) {
      $0.isReportCommentShown = false
      $0.isReportMenuShown = false
    }
    await store.send(.cardDoubleTapped) {
      $0.isReportMenuShown = true
    }
    let task = await store.send(.reportReasonTapped(.wrong)) {
      $0.isReportMenuShown = false
      $0.isReviewing = true
    }
    await task.cancel()
  }

  @Test func askingClosesTheMenu() async {
    var state = revealed(cards)
    state.isReportMenuShown = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.askAI.copy = { _ in }
      $0.askAI.open = { _ in true }
      $0.continuousClock = ImmediateClock()
    }

    await store.send(.askTapped) {
      $0.isReportMenuShown = false
    }
    await store.receive(\.askOpened) {
      $0.notice = .copied
    }
    await store.receive(\.noticeExpired) {
      $0.notice = nil
    }
  }

  @Test func theMenuIsOffNotRevealedEditingOrWithARequestInFlight() async {
    var unrevealed = studying(cards)
    var editing = revealed(cards)
    editing.editing = .back
    var reviewing = revealed(cards)
    reviewing.isReviewing = true
    for state in [unrevealed, editing, reviewing] {
      let store = TestStore(initialState: state) { StudyFeature() }
      await store.send(.cardDoubleTapped)
      await store.send(.askTapped)
      await store.send(.reportReasonTapped(.wrong))
    }
    unrevealed.phase = .offline
    let store = TestStore(initialState: unrevealed) { StudyFeature() }
    await store.send(.cardDoubleTapped)
  }

  @Test func theMenuOffersTheFiveReasonsButNotBrokenPhoto() {
    #expect(StudyView.reportReasons.map(\.reason) == [.wrong, .drop, .doubt, .rephrase, .other])
    #expect(StudyView.reportReasons.map(\.title) == [
      "This is wrong", "I don't want this card", "I doubt this is correct", "I want it phrased differently", "Other…",
    ])
  }

  @Test(arguments: [ReportReason.wrong, .drop, .doubt, .rephrase])
  func aReasonReportsTheCardAndShowsTheNextOneWithANotice(reason: ReportReason) async {
    let sent = LockIsolated<[(Card.ID, ReportReason, String?)]>([])
    let clock = TestClock()
    let store = TestStore(initialState: revealed(cards)) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.apiClient.reportCard = { id, reason, comment in sent.withValue { $0.append((id, reason, comment)) } }
      $0.apiClient.stats = { .plain }
    }

    await store.send(.reportReasonTapped(reason)) {
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
    #expect(sent.value.map(\.0) == [cards[0].id])
    #expect(sent.value.map(\.1) == [reason])
    #expect(sent.value.map(\.2) == [nil])

    await clock.advance(by: .seconds(2))
    await store.receive(\.noticeExpired) {
      $0.notice = nil
    }
  }

  @Test func otherAsksForACommentAndSendsItTrimmed() async {
    let sent = LockIsolated<[(ReportReason, String?)]>([])
    let clock = TestClock()
    var state = revealed(cards)
    state.reportComment = "stale"
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.apiClient.reportCard = { _, reason, comment in sent.withValue { $0.append((reason, comment)) } }
      $0.apiClient.stats = { .plain }
    }

    await store.send(.reportReasonTapped(.other)) {
      $0.reportComment = ""
      $0.isReportCommentShown = true
    }
    await store.send(.binding(.set(\.reportComment, "  "))) {
      $0.reportComment = "  "
    }
    await store.send(.reportCommentSubmitted)
    await store.send(.binding(.set(\.reportComment, " typo in the answer "))) {
      $0.reportComment = " typo in the answer "
    }
    await store.send(.reportCommentSubmitted) {
      $0.isReportCommentShown = false
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
    #expect(sent.value.map(\.0) == [.other])
    #expect(sent.value.map(\.1) == ["typo in the answer"])
    await clock.advance(by: .seconds(2))
    await store.receive(\.noticeExpired) {
      $0.notice = nil
    }
  }

  @Test func cancellingTheCommentSendsNothing() async {
    let store = TestStore(initialState: revealed(cards)) { StudyFeature() }

    await store.send(.reportReasonTapped(.other)) {
      $0.isReportCommentShown = true
    }
    await store.send(.binding(.set(\.isReportCommentShown, false))) {
      $0.isReportCommentShown = false
    }
  }

  /// Spec 021 (QA): the API holds the reported card, so the counter drops it ("3 new" → "2 new").
  @Test func aReportRefreshesTheCounter() async {
    let before = DeckStats(total: 3, due: 3, new: 3, reviewedToday: 0, nextDue: nil, dueNew: 3)
    let after = DeckStats(total: 3, due: 2, new: 2, reviewedToday: 0, nextDue: nil, dueNew: 2)
    let clock = TestClock()
    let store = TestStore(initialState: revealed(cards, ladder: before)) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.apiClient.reportCard = { _, _, _ in }
      $0.apiClient.stats = { after }
    }
    #expect(store.state.ladder?.counter?.count == 3)

    await store.send(.reportReasonTapped(.drop)) {
      $0.isReviewing = true
    }
    await store.receive(\.reportResponse) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
      $0.notice = .reported
    }
    await store.receive(\.ladderResponse) {
      $0.ladder = Ladder(stats: after)
    }
    #expect(store.state.ladder?.counter?.count == 2)
    await clock.advance(by: StudyFeature.noticeDuration)
    await store.receive(\.noticeExpired) {
      $0.notice = nil
    }
  }

  /// Reporting the last at-risk card finishes the step, but only a rating announces one (spec 021 decision 8).
  @Test func aReportThatEmptiesAStepShowsNoStepNotice() async {
    let clock = TestClock()
    let before = DeckStats(total: 3, due: 3, new: 0, reviewedToday: 0, nextDue: nil, atRiskTotal: 3, atRiskDone: 2)
    let after = DeckStats(total: 3, due: 2, new: 0, reviewedToday: 0, nextDue: nil, atRiskTotal: 2, atRiskDone: 2)
    #expect(Ladder(stats: after).notice(after: Ladder(stats: before)) == "At risk")
    let store = TestStore(initialState: revealed(cards, ladder: before)) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.apiClient.reportCard = { _, _, _ in }
      $0.apiClient.stats = { after }
    }

    await store.send(.reportReasonTapped(.wrong)) {
      $0.isReviewing = true
    }
    await store.receive(\.reportResponse) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
      $0.notice = .reported
    }
    await store.receive(\.ladderResponse) {
      $0.ladder = Ladder(stats: after)
    }
    await clock.advance(by: StudyFeature.noticeDuration)
    await store.receive(\.noticeExpired) {
      $0.notice = nil
    }
  }

  @Test func reportingTheLastCardShowsCaughtUp() async {
    let clock = TestClock()
    let store = TestStore(initialState: revealed([cards[0]])) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.apiClient.isConfigured = { true }
      $0.apiClient.reportCard = { _, _, _ in }
      $0.apiClient.dueCards = { _ in [] }
      // The reported card is held, not deleted: it still counts in `total` (spec 015 decision 7).
      $0.apiClient.stats = { DeckStats(total: 1, due: 0, new: 0, reviewedToday: 0, nextDue: nil) }
    }

    await store.send(.reportReasonTapped(.drop)) {
      $0.isReviewing = true
    }
    await store.receive(\.reportResponse) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards = []
      $0.notice = .reported
    }
    await store.receive(\.queueResponse) {
      $0.ladder = Ladder(stats: .plain)
      $0.phase = .caughtUp(nextDue: nil)
    }
    await clock.advance(by: .seconds(2))
    await store.receive(\.noticeExpired) {
      $0.notice = nil
    }
    await store.send(.scenePhaseChanged(.background))
  }

  @Test func aFailedReportKeepsTheCardAndSaysSoUntilTheNextRating() async {
    let clock = TestClock()
    let store = TestStore(initialState: revealed(cards)) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.stats = { .plain }
      $0.continuousClock = clock
      $0.apiClient.reportCard = { _, _, _ in throw Offline() }
      $0.apiClient.review = { _, _ in cards[0] }
    }

    await store.send(.reportReasonTapped(.wrong)) {
      $0.isReviewing = true
    }
    await store.receive(\.reportResponse) {
      $0.isReviewing = false
      $0.notice = .failed
    }
    await clock.advance(by: .seconds(5))
    await store.send(.ratingTapped(.good)) {
      $0.isReviewing = true
      $0.notice = nil
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
    await store.receive(\.ladderResponse) {
      $0.ladder = Ladder(stats: .plain)
    }
  }

  @Test func refreshIsSkippedWhileAReportIsInFlight() async {
    var state = revealed(cards)
    state.isReviewing = true
    let store = TestStore(initialState: state) { StudyFeature() }

    await store.send(.scenePhaseChanged(.active))
  }

  @Test func askWithCopyOnlyCopiesTheCardAndSaysCopiedWithoutARequest() async {
    let copied = LockIsolated<[String]>([])
    let clock = TestClock()
    var state = revealed(cards)
    state.$aiApp.withLock { $0 = .copyOnly }
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.askAI.copy = { text in copied.withValue { $0.append(text) } }
    }

    await store.send(.askTapped) {
      $0.notice = .copied
    }
    #expect(copied.value == [AskText.make(for: cards[0])])
    await clock.advance(by: .seconds(2))
    await store.receive(\.noticeExpired) {
      $0.notice = nil
    }
  }

  @Test(arguments: [(true, StudyFeature.State.Notice.copied), (false, .copiedNotInstalled("Claude"))])
  func askCopiesThenOpensThePickedApp(opened: Bool, notice: StudyFeature.State.Notice) async {
    let calls = LockIsolated<[String]>([])
    let clock = TestClock()
    var state = revealed(cards)
    state.$aiApp.withLock { $0 = .claude }
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.askAI.copy = { text in calls.withValue { $0.append("copy \(text)") } }
      $0.askAI.open = { url in
        calls.withValue { $0.append("open \(url.absoluteString)") }
        return opened
      }
    }

    await store.send(.askTapped)
    await store.receive(\.askOpened) {
      $0.notice = notice
    }
    let text = AskText.make(for: cards[0])
    #expect(calls.value == ["copy \(text)", "open \(AIApp.claude.link(for: text)!.absoluteString)"])
    await clock.advance(by: .seconds(2))
    await store.receive(\.noticeExpired) {
      $0.notice = nil
    }
  }

  @Test func theDefaultVibeNotInstalledSaysSo() async {
    let store = TestStore(initialState: revealed(cards)) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.askAI.copy = { _ in }
      $0.askAI.open = { url in
        #expect(url == AIApp.vibe.link(for: AskText.make(for: cards[0])))
        return false
      }
    }

    await store.send(.askTapped)
    await store.receive(\.askOpened) {
      $0.notice = .copiedNotInstalled("Vibe")
    }
    await store.receive(\.noticeExpired) {
      $0.notice = nil
    }
  }

  @Test func theNotInstalledNoticeNamesTheApp() {
    #expect(StudyView.text(.copiedNotInstalled("Vibe")) == "Copied · Vibe isn't installed")
  }

  @Test func aRatingAnEditOrAReportClearsCopied() async {
    var state = revealed(cards)
    state.notice = .copied
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.stats = { .plain }
      $0.apiClient.review = { _, _ in cards[0] }
      $0.apiClient.reportCard = { _, _, _ in throw Offline() }
    }

    await store.send(.textDoubleTapped(.back)) {
      $0.editing = .back
      $0.draft = self.cards[0].back
      $0.notice = nil
    }
    await store.send(.editEnded) {
      $0.editing = nil
    }
    store.exhaustivity = .off
    await store.send(.binding(.set(\.notice, .copied)))
    await store.send(.reportReasonTapped(.wrong)) {
      $0.notice = nil
    }
    await store.receive(\.reportResponse)
    await store.send(.binding(.set(\.notice, .copied)))
    await store.send(.ratingTapped(.good)) {
      $0.notice = nil
    }
    await store.receive(\.reviewResponse)
  }

  @Test func aBrokenPromptPhotoIsReportedOnceAndSkippedSilently() async {
    let sent = LockIsolated<[(Card.ID, ReportReason, String?)]>([])
    let photoCard = Card(note: person, card: person.cards[0])
    let store = TestStore(initialState: studying([photoCard, cards[0]])) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.reportCard = { id, reason, comment in sent.withValue { $0.append((id, reason, comment)) } }
      $0.apiClient.stats = { .plain }
    }
    let url = String(repeating: "x", count: 600)

    await store.send(.photoLoadFailed(cardID: photoCard.id, url: url, side: .front)) {
      $0.reportedBrokenPhotos = [photoCard.id]
      $0.cards.removeFirst()
    }
    await store.receive(\.brokenPhotoReportResponse)
    // The API holds the skipped card: the counter drops it, as after a report.
    await store.receive(\.ladderResponse) {
      $0.ladder = Ladder(stats: .plain)
    }
    #expect(sent.value.map(\.0) == [photoCard.id])
    #expect(sent.value.map(\.1) == [.brokenPhoto])
    #expect(sent.value.map(\.2) == [String(repeating: "x", count: 500)])

    // The report may not have landed: the card is not served again this session, nor reported twice.
    await store.send(.queueResponse(.success(.init(cards: [photoCard, cards[0]], stats: .plain)), afterRating: false))
    await store.send(.photoLoadFailed(cardID: photoCard.id, url: url, side: .front))
    #expect(sent.value.count == 1)
  }

  @Test func skippingTheLastCardRefetchesOnlyOnceTheReportLanded() async {
    let photoCard = Card(note: person, card: person.cards[0])
    let sibling = Card(note: person, card: person.cards[1])
    let held = LockIsolated(false)
    let store = TestStore(initialState: studying([photoCard])) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.stats = { .plain }
      $0.apiClient.isConfigured = { true }
      $0.apiClient.reportCard = { _, _, _ in held.setValue(true) }
      // Sibling burying: the API serves the sibling only once the photo card is held.
      $0.apiClient.dueCards = { _ in held.value ? [sibling] : [photoCard] }
    }

    await store.send(.photoLoadFailed(cardID: photoCard.id, url: "https://example.org/a.jpg", side: .front)) {
      $0.reportedBrokenPhotos = [photoCard.id]
      $0.cards = []
      $0.phase = .loading
    }
    await store.receive(\.brokenPhotoReportResponse)
    await store.receive(\.queueResponse) {
      $0.ladder = Ladder(stats: .plain)
      $0.cards = [sibling]
      $0.phase = .studying
    }
  }

  @Test func aSkippedCardWhoseReportFailedComesBackOnTheNextLoad() async {
    let photoCard = Card(note: person, card: person.cards[0])
    let store = TestStore(initialState: studying([photoCard])) {
      StudyFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.apiClient.isConfigured = { true }
      $0.apiClient.reportCard = { _, _, _ in throw Offline() }
      $0.apiClient.dueCards = { _ in [photoCard] }
      $0.apiClient.stats = { DeckStats(total: 1, due: 1, new: 1, reviewedToday: 0, nextDue: nil) }
    }

    await store.send(.photoLoadFailed(cardID: photoCard.id, url: "https://example.org/a.jpg", side: .front)) {
      $0.reportedBrokenPhotos = [photoCard.id]
      $0.cards = []
      $0.phase = .loading
    }
    await store.receive(\.brokenPhotoReportResponse) {
      $0.reportedBrokenPhotos = []
    }
    await store.receive(\.queueResponse) {
      $0.ladder = Ladder(stats: .plain)
      $0.phase = .caughtUp(nextDue: nil)
    }
    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.queueResponse) {
      $0.ladder = Ladder(stats: .plain)
      $0.cards = [photoCard]
      $0.phase = .studying
    }
  }

  @Test func aBrokenAnswerPhotoIsReportedOnceAndTheCardStays() async {
    let sent = LockIsolated<[(Card.ID, ReportReason)]>([])
    let nameCard = Card(note: person, card: person.cards[1])
    let store = TestStore(initialState: studying([nameCard, cards[0]])) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.reportCard = { id, reason, _ in sent.withValue { $0.append((id, reason)) } }
      $0.apiClient.stats = { .plain }
    }

    await store.send(.photoLoadFailed(cardID: nameCard.id, url: "https://example.org/a.jpg", side: .back)) {
      $0.reportedBrokenPhotos = [nameCard.id]
    }
    await store.receive(\.brokenPhotoReportResponse)
    await store.receive(\.ladderResponse) {
      $0.ladder = Ladder(stats: .plain)
    }
    await store.send(.queueResponse(.success(.init(cards: [nameCard, cards[0]], stats: .plain)), afterRating: false))
    await store.send(.photoLoadFailed(cardID: nameCard.id, url: "https://example.org/a.jpg", side: .back))
    #expect(sent.value.map(\.0) == [nameCard.id])
    #expect(sent.value.map(\.1) == [.brokenPhoto])
  }

  @Test func aLatePhotoFailureOfAnotherCardSkipsNothing() async {
    let photoCard = Card(note: person, card: person.cards[0])
    let store = TestStore(initialState: studying(cards)) {
      StudyFeature()
    } withDependencies: {
      $0.apiClient.reportCard = { _, _, _ in }
      $0.apiClient.stats = { .plain }
    }

    await store.send(.photoLoadFailed(cardID: photoCard.id, url: "https://example.org/a.jpg", side: .front)) {
      $0.reportedBrokenPhotos = [photoCard.id]
    }
    await store.receive(\.brokenPhotoReportResponse)
    await store.receive(\.ladderResponse) {
      $0.ladder = Ladder(stats: .plain)
    }
  }

  private func revealed(_ cards: [Card], ladder: DeckStats? = nil) -> StudyFeature.State {
    var state = studying(cards)
    state.isRevealed = true
    state.ladder = ladder.map(Ladder.init)
    return state
  }

  private func studying(_ cards: [Card]) -> StudyFeature.State {
    var state = StudyFeature.State()
    state.cards = IdentifiedArray(uniqueElements: cards)
    state.phase = .studying
    return state
  }
}

/// Spec 016a #3: the exact text handed to an AI app.
struct AskTextTests {
  let date = Date(timeIntervalSince1970: 1_767_225_600)
  let id = UUID(uuidString: "65F15766-7AB3-4C84-BB05-AE180E083BEF")!

  @Test func aBasicCardIsItsTwoTexts() {
    let card = Card(id: id, front: "la carte", back: "the menu — and the map", due: date, createdAt: date, updatedAt: date)
    #expect(
      AskText.make(for: card)
        == "This is the card 65f15766-7ab3-4c84-bb05-ae180e083bef in the La Carte flashcard app.\n"
        + "Question: la carte\nAnswer: the menu — and the map\n\n"
    )
  }

  @Test func aReversedBasicCardSwapsThem() {
    var card = Card(id: id, front: "la carte", back: "the menu — and the map", due: date, createdAt: date, updatedAt: date)
    card.prompt = ["back"]
    card.answer = ["front"]
    #expect(AskText.make(for: card).hasSuffix("Question: the menu — and the map\nAnswer: la carte\n\n"))
  }

  @Test func aPersonCardLabelsEveryField() {
    let card = person(["photo": "https://example.com/ada.jpg", "name": "Ada Lovelace", "description": "First programmer"])
    #expect(
      AskText.make(for: card)
        == "This is the card 65f15766-7ab3-4c84-bb05-ae180e083bef in the La Carte flashcard app.\n"
        + "Question: Photo: https://example.com/ada.jpg\nAnswer: Name: Ada Lovelace; Description: First programmer\n\n"
    )
  }

  @Test func anEmptyFieldIsSkipped() {
    let card = person(["photo": "https://example.com/ada.jpg", "name": "Ada Lovelace", "description": ""])
    #expect(AskText.make(for: card).hasSuffix("Question: Photo: https://example.com/ada.jpg\nAnswer: Name: Ada Lovelace\n\n"))
  }

  private func person(_ fields: [String: String]) -> Card {
    let note = Note(
      id: UUID(), type: .person, fields: fields,
      cards: [Note.Card(id: id, prompt: ["photo"], answer: ["name"], due: date)],
      createdAt: date, updatedAt: date
    )
    return Card(note: note, card: note.cards[0])
  }
}
