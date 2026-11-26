import APIClient
import ActivityClient
import AskAIClient
import ComposableArchitecture
import DesignSystem
import Foundation
import SwiftUI

/// The home screen: reviews due cards one at a time, then says when the next one is due (spec 001).
@Reducer
public struct StudyFeature {
  @ObservableState
  public struct State: Equatable {
    var cards: IdentifiedArrayOf<Card> = []
    var isRevealed = false
    var isReviewing = false
    var phase: Phase = .loading
    var editing: Field?
    var draft = ""
    var isSavingEdit = false
    var editFailed = false
    /// The continuous ease value 0...1 while a rating drag is held; nil = no dial (spec 011).
    var swipeEase: Double?
    /// The grade a drag released: the rating row keeps echoing it until the next card (spec 019).
    var releasedRating: Rating?
    var isReportMenuShown = false
    /// The day's steps from the last `/stats` (spec 021); nil until the first load answers.
    var ladder: Ladder?
    var isMilestonesShown = false
    var isReportCommentShown = false
    var reportComment = ""
    /// Shown in the counter slot: a report's or a copy's outcome (specs 015, 016).
    var notice: Notice?
    /// Cards whose broken photo was reported this session: sent once, and never served again (spec 015 #13-15).
    var reportedBrokenPhotos: Set<Card.ID> = []
    /// Picked in Settings (spec 016b).
    @Shared(.appStorage(AIApp.storageKey)) var aiApp: AIApp = .vibe
    @ObservationStateIgnored var activityTrail = ActivityTrail()

    /// What releasing the drag now would send.
    var swipeRating: Rating? { swipeEase.flatMap(StudyFeature.rating(forEase:)) }

    /// What the rating row shows on the drag's side (spec 019): the grade a release would give, or the side's
    /// first grade (not armed) in the dead zone. Nil = at rest, including at the touch-down point.
    var rowEcho: RowEcho? {
      if let releasedRating { return RowEcho(rating: releasedRating, isArmed: true) }
      // ≈ 2 pt of drag: below it, touch-down jitter keeps the row at rest.
      guard let ease = swipeEase, abs(ease - 0.5) >= 0.01 else { return nil }
      return RowEcho(rating: swipeRating ?? (ease > 0.5 ? .good : .hard), isArmed: swipeRating != nil)
    }

    /// The card text fades to 0.3 across the dead zone, so a nudge keeps the answer readable (spec 019).
    var cardTextOpacity: Double {
      guard let ease = swipeEase else { return 1 }
      return 1 - 0.7 * min(abs(ease - 0.5) * 2 / 0.3, 1)
    }

    /// The buttons can be tapped, a drag can rate, and VoiceOver offers the ratings.
    var canRate: Bool {
      phase == .studying && isRevealed && editing == nil && !isReviewing
    }

    /// The double-tap menu (report, ask) is offered exactly when the card can be rated.
    var canReport: Bool { canRate }

    /// Inline edit (010) needs one text field on each side; photo and multi-field cards use the deck editor (014d).
    var canEditInline: Bool {
      guard let card = cards.first else { return false }
      return card.type == .basic && card.prompt.count == 1 && card.answer.count == 1 && !card.prompt.contains(Card.photoField)
        && !card.answer.contains(Card.photoField)
    }

    /// What a person card asks to recall, from its answer labels: "Name and description?". Nil for basic cards.
    var answerHint: String? {
      guard let card = cards.first, card.type == .person else { return nil }
      let list = card.shown(card.answer).formatted(.list(type: .and).locale(Locale(identifier: "en_US")))
      return list.prefix(1).uppercased() + list.dropFirst() + "?"
    }

    public init() {}

    /// The side of the revealed card being edited in place (spec 010).
    public enum Field: Hashable, Sendable {
      case front, back
    }

    struct RowEcho: Equatable {
      var rating: Rating
      /// Releasing now sends `rating`; false in the dead zone.
      var isArmed: Bool
    }

    enum Notice: Equatable {
      case reported, failed, copied, copiedNotInstalled(String)
      /// A ladder step a rating just completed: its label ("At risk", "15 new").
      case stepDone(String)

      var isStepDone: Bool {
        if case .stepDone = self { true } else { false }
      }
    }

    enum Phase: Equatable {
      /// `empty` only when the deck has no card at all: held (reported) cards still count (spec 015 decision 7).
      case loading, studying, caughtUp(nextDue: Date?), empty, offline, notSetUp, unauthorized
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    /// Not a binding: ending the edit on a typed newline needs the draft before and after.
    case draftChanged(String)
    case onAppear
    case revealTapped
    case cardTapped
    case textDoubleTapped(State.Field)
    case editEnded
    case ratingTapped(Rating)
    case swipeChanged(fraction: Double)
    case swipeEnded(fraction: Double)
    case retryButtonTapped
    case deckButtonTapped
    case addButtonTapped
    case openSettingsTapped
    case deckChanged
    case scenePhaseChanged(ScenePhase)
    /// The caught-up / empty / offline timer elapsed (spec 018).
    case autoRefreshFired
    case remainingTapped
    case queueResponse(Result<Queue, any Error>, afterRating: Bool)
    /// The stats fetched after a rating or a report that left cards in the batch; only a rating shows a step notice.
    case ladderResponse(Result<DeckStats, any Error>, afterRating: Bool)
    case reviewResponse(Result<Card, any Error>)
    case editSaveResponse(Result<Card, any Error>, previous: Card)
    case cardDoubleTapped
    case askTapped
    case askOpened(Bool)
    case reportReasonTapped(ReportReason)
    case reportCommentSubmitted
    case reportResponse(Result<Void, any Error>, cardID: Card.ID)
    case brokenPhotoReportResponse(Result<Void, any Error>, cardID: Card.ID)
    case noticeExpired
    /// A photo on the card couldn't be loaded (error or 10 s timeout); `side` is where it shows.
    case photoLoadFailed(cardID: Card.ID, url: String, side: State.Field)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case deckRequested, addCardRequested, settingsRequested
    }
  }

  @Dependency(\.activity) var activity
  @Dependency(\.apiClient) var apiClient
  @Dependency(\.askAI) var askAI
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date) var date

  /// One queue load: the due cards and the stats, fetched together (spec 021 decision 7).
  public struct Queue: Sendable {
    var cards: [Card]
    var stats: DeckStats
  }

  private enum CancelID { case load, ladder, notice, autoRefresh }

  /// How often Study checks for new cards while there is nothing to study (spec 018).
  static let autoRefreshInterval: Duration = .seconds(30)

  public init() {}

  /// How long a notice stays: 2 s; `-noticeSeconds <s>` (debug builds) lengthens it so slow UI-test runners see it.
  static let noticeDuration: Duration = {
    #if DEBUG
      let seconds = UserDefaults.standard.double(forKey: "noticeSeconds")
      if seconds > 0 { return .seconds(seconds) }
    #endif
    return .seconds(2)
  }()

  /// The drag's scale: the ring's radius as a fraction of the card's width.
  static let ringRadius = 0.25

  /// The drag projected on the up-right diagonal, in card widths (spec 019): `clamp(dx − dy, −d, d)`, so right,
  /// up and up-right count the full distance as positive, left, down and down-left as negative, and the
  /// up-left / down-right diagonals cancel. `translation` is in screen points (y down).
  static func swipeFraction(translation: CGSize, cardWidth: CGFloat) -> Double {
    guard cardWidth > 0 else { return 0 }
    let distance = hypot(translation.width, translation.height)
    return min(max(translation.width - translation.height, -distance), distance) / cardWidth
  }

  /// The ease value for a drag of `fraction` card widths: 0.5 at touch-down, 0 or 1 on the ring.
  static func ease(forSwipe fraction: Double) -> Double {
    min(max(0.5 + fraction / (2 * ringRadius), 0), 1)
  }

  /// FSRS takes four grades; the middle band is a dead zone so going back to the start cancels.
  static func rating(forEase ease: Double) -> Rating? {
    switch ease {
    case ...RatingBands.forgot: .again
    case ...RatingBands.hard: .hard
    case ..<RatingBands.gotIt: nil
    case ..<RatingBands.easy: .good
    default: .easy
    }
  }

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.isReportCommentShown):
        // The comment alert sits on the menu sheet: cancelling it closes both.
        if !state.isReportCommentShown { state.isReportMenuShown = false }
        return .none

      case .binding:
        return .none

      case let .draftChanged(draft):
        // A vertical field types return instead of submitting (iOS 27): a typed newline ends the edit.
        guard let kept = Self.droppingTypedNewlines(old: state.draft, new: draft) else {
          state.draft = draft
          return .none
        }
        state.draft = kept
        return endEdit(&state)

      case .onAppear, .deckChanged:
        return fetchQueue(&state)

      case .autoRefreshFired, .scenePhaseChanged(.active):
        // The review's or the edit's response updates the queue; a list fetched meanwhile could undo it.
        // While editing, a new list could replace the card under the user's fingers.
        // Dropped, the timer starts over from the current phase (none while studying).
        guard !state.isReviewing, state.editing == nil, !state.isSavingEdit else { return armAutoRefresh(state) }
        return fetchQueue(&state)

      case .scenePhaseChanged(.background):
        return .cancel(id: CancelID.autoRefresh)

      case .scenePhaseChanged:
        return .none

      case .retryButtonTapped:
        state.phase = .loading
        return .merge(.cancel(id: CancelID.autoRefresh), fetchQueue(&state))

      case .revealTapped:
        state.isRevealed = true
        return .none

      case .cardTapped:
        state.isRevealed = true
        return .none

      case let .textDoubleTapped(field):
        guard state.isRevealed, state.editing == nil, !state.isSavingEdit, state.phase == .studying,
          state.canEditInline, let card = state.cards.first
        else { return .none }
        state.editing = field
        state.draft = card.text(field)
        state.editFailed = false
        state.notice = nil
        return .cancel(id: CancelID.load)

      case .editEnded:
        return endEdit(&state)

      case let .editSaveResponse(result, previous):
        state.isSavingEdit = false
        guard state.cards[id: previous.id] != nil else { return .none }
        switch result {
        case let .success(card):
          state.cards[id: card.id] = card
        case .failure:
          state.cards[id: previous.id] = previous
          state.editFailed = true
        }
        return .none

      case let .ratingTapped(rating):
        return review(rating, state: &state)

      case let .swipeChanged(fraction):
        guard state.canRate else { return .none }
        state.swipeEase = Self.ease(forSwipe: fraction)
        return .none

      case let .swipeEnded(fraction):
        // A drag can outlive `canRate` (a refresh fails mid-drag): the release always clears the ring.
        state.swipeEase = nil
        guard state.canRate, let rating = Self.rating(forEase: Self.ease(forSwipe: fraction)) else { return .none }
        state.releasedRating = rating
        return review(rating, state: &state)

      case .deckButtonTapped:
        return .merge(endEdit(&state), .send(.delegate(.deckRequested)))

      case .addButtonTapped:
        return .merge(endEdit(&state), .send(.delegate(.addCardRequested)))

      case .openSettingsTapped:
        return .send(.delegate(.settingsRequested))

      case .remainingTapped:
        guard state.ladder != nil else { return .none }
        state.isMilestonesShown = true
        return .none

      case let .queueResponse(.success(queue), afterRating):
        var cards = queue.cards
        let notice = updateLadder(&state, stats: queue.stats, afterRating: afterRating)
        // The report may not have landed yet (or failed): a skipped card must not come back.
        cards.removeAll { $0.id != state.cards.first?.id && state.reportedBrokenPhotos.contains($0.id) }
        // Never yank the visible card: while the server still serves it, it stays first.
        if let index = cards.firstIndex(where: { $0.id == state.cards.first?.id }) {
          cards.insert(cards.remove(at: index), at: 0)
        }
        if cards.first?.id != state.cards.first?.id {
          state.isRevealed = false
          state.swipeEase = nil
        }
        state.cards = IdentifiedArray(uniqueElements: cards)
        if cards.isEmpty {
          state.phase = queue.stats.total == 0 ? .empty : .caughtUp(nextDue: queue.stats.nextDue)
        } else {
          state.phase = .studying
        }
        return .merge(notice, armAutoRefresh(state))

      case let .ladderResponse(.success(stats), afterRating):
        return updateLadder(&state, stats: stats, afterRating: afterRating)

      case .ladderResponse(.failure, _):
        return .none

      case let .reviewResponse(.success(card)):
        state.isReviewing = false
        state.releasedRating = nil
        state.isRevealed = false
        state.cards.remove(id: card.id)
        return state.cards.isEmpty ? fetchQueue(&state, afterRating: true) : fetchLadder(afterRating: true)

      case let .queueResponse(.failure(error), _), let .reviewResponse(.failure(error)):
        state.isReviewing = false
        // The card and its pan leave the screen, so a held drag may never send its release.
        state.swipeEase = nil
        state.releasedRating = nil
        state.phase = (error as? APIError)?.isUnauthorized == true ? .unauthorized : .offline
        return armAutoRefresh(state)

      case .cardDoubleTapped:
        guard state.canReport else { return .none }
        state.isReportMenuShown = true
        return .none

      case .askTapped:
        guard state.canReport, let card = state.cards.first else { return .none }
        state.isReportMenuShown = false
        let text = AskText.make(for: card)
        let url = state.aiApp.link(for: text)
        state.notice = .copied
        return .merge(
          .run { [askAI] send in
            askAI.copy(text)
            if let url { await send(.askOpened(askAI.open(url))) }
          },
          expireNotice()
        )

      case .askOpened(true):
        return .none

      case .askOpened(false):
        state.notice = .copiedNotInstalled(state.aiApp.title)
        return expireNotice()

      case .reportReasonTapped(.other):
        state.reportComment = ""
        state.isReportCommentShown = true
        return .none

      case let .reportReasonTapped(reason):
        return report(reason, comment: nil, state: &state)

      case .reportCommentSubmitted:
        let comment = state.reportComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else { return .none }
        state.isReportCommentShown = false
        return report(.other, comment: comment, state: &state)

      case let .reportResponse(.success, cardID):
        state.isReviewing = false
        state.isRevealed = false
        state.cards.remove(id: cardID)
        state.notice = .reported
        // The API holds the card: the counter drops it, without a step notice.
        return .merge(expireNotice(), state.cards.isEmpty ? fetchQueue(&state) : fetchLadder(afterRating: false))

      case .reportResponse(.failure, _):
        state.isReviewing = false
        state.notice = .failed
        return .none

      case .noticeExpired:
        if state.notice != .failed { state.notice = nil }
        return .none

      case let .photoLoadFailed(cardID, url, side):
        // A broken answer photo leaves the card studyable; a broken prompt can't be asked, so it's skipped.
        if side == .front, state.cards.first?.id == cardID {
          state.cards.removeFirst()
          state.isRevealed = false
          state.swipeEase = nil
        }
        guard state.reportedBrokenPhotos.insert(cardID).inserted else {
          return state.cards.isEmpty && state.phase == .studying ? fetchQueue(&state) : .none
        }
        // Until the report lands the API still serves this card instead of its sibling: the refetch waits for it.
        if state.cards.isEmpty, state.phase == .studying { state.phase = .loading }
        let comment = String(url.prefix(500))
        return .run { [apiClient] send in
          await send(
            .brokenPhotoReportResponse(Result { try await apiClient.reportCard(cardID, .brokenPhoto, comment) }, cardID: cardID)
          )
        }

      case .brokenPhotoReportResponse(.success, _):
        return state.cards.isEmpty && state.phase == .loading ? fetchQueue(&state) : fetchLadder(afterRating: false)

      case let .brokenPhotoReportResponse(.failure, cardID):
        // Not held by the API, so it may come back on the next load; refetching now would only loop on it.
        state.reportedBrokenPhotos.remove(cardID)
        guard state.cards.isEmpty, state.phase == .loading else { return .none }
        // Stats only, for caught up: refetching the cards would serve the broken photo again.
        return .run { [apiClient] send in
          await send(.queueResponse(Result { try await Queue(cards: [], stats: apiClient.stats()) }, afterRating: false))
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)

      case .delegate:
        return .none
      }
    }
    activityLogging
  }

  private func review(_ rating: Rating, state: inout State) -> Effect<Action> {
    guard !state.isReviewing, let card = state.cards.first else { return .none }
    state.isReviewing = true
    state.editFailed = false
    state.notice = nil
    // A load in flight may predate the review and would bring the rated card back.
    return .merge(
      .cancel(id: CancelID.load),
      .run { [apiClient] send in
        await send(.reviewResponse(Result { try await apiClient.review(card.id, rating) }))
      }
    )
  }

  /// Sends the report as a rating would: it blocks the buttons, the drag and refresh until it's answered.
  private func report(_ reason: ReportReason, comment: String?, state: inout State) -> Effect<Action> {
    guard state.canReport, let card = state.cards.first else { return .none }
    state.isReportMenuShown = false
    state.isReviewing = true
    state.editFailed = false
    state.notice = nil
    return .merge(
      .cancel(id: CancelID.load),
      .run { [apiClient] send in
        await send(.reportResponse(Result { try await apiClient.reportCard(card.id, reason, comment) }, cardID: card.id))
      }
    )
  }

  /// One quiet reload when the next card is due (at most 30 s, at least 1 s away), or every 30 s while there is
  /// nothing to study, to pick up cards an agent adds. Any other phase stops it (spec 018).
  private func armAutoRefresh(_ state: State) -> Effect<Action> {
    let delay: Duration
    switch state.phase {
    case let .caughtUp(nextDue?):
      let untilDue = Duration.seconds(nextDue.timeIntervalSince(date.now))
      delay = min(max(untilDue, .seconds(1)), Self.autoRefreshInterval)
    case .caughtUp(nil), .empty, .offline:
      delay = Self.autoRefreshInterval
    case .loading, .studying, .notSetUp, .unauthorized:
      return .cancel(id: CancelID.autoRefresh)
    }
    return .run { [clock] send in
      try await clock.sleep(for: delay)
      await send(.autoRefreshFired)
    }
    .cancellable(id: CancelID.autoRefresh, cancelInFlight: true)
  }

  /// Only the latest post-rating (or post-report) stats land.
  private func fetchLadder(afterRating: Bool) -> Effect<Action> {
    .run { [apiClient] send in
      await send(.ladderResponse(Result { try await apiClient.stats() }, afterRating: afterRating))
    }
    .cancellable(id: CancelID.ladder, cancelInFlight: true)
  }

  /// Stores the new ladder; after a rating, a step it completed shows its notice (spec 021 decision 8).
  private func updateLadder(_ state: inout State, stats: DeckStats, afterRating: Bool) -> Effect<Action> {
    let ladder = Ladder(stats: stats)
    let step = afterRating ? state.ladder.flatMap { ladder.notice(after: $0) } : nil
    state.ladder = ladder
    guard let step else { return .none }
    state.notice = .stepDone(step)
    return expireNotice()
  }

  private func expireNotice() -> Effect<Action> {
    .run { [clock] send in
      try await clock.sleep(for: Self.noticeDuration)
      await send(.noticeExpired)
    }
    .cancellable(id: CancelID.notice, cancelInFlight: true)
  }

  /// Saves the edited side optimistically: the trimmed text shows at once and the server's card replaces it.
  /// An unchanged or blank text just ends the edit. Idempotent, since focus loss can follow Done.
  /// `new` without the newlines typed since `old` (the card's own newlines stay), or nil if none were typed.
  static func droppingTypedNewlines(old: String, new: String) -> String? {
    let prefix = zip(old, new).prefix { $0 == $1 }.count
    let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
    let typed = new.dropFirst(prefix).dropLast(suffix)
    guard typed.contains(where: \.isNewline) else { return nil }
    return String(new.prefix(prefix)) + typed.filter { !$0.isNewline } + String(new.suffix(suffix))
  }

  private func endEdit(_ state: inout State) -> Effect<Action> {
    guard let field = state.editing, let previous = state.cards.first else { return .none }
    state.editing = nil
    let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    var card = previous
    card.setText(text, for: field)
    guard !text.isEmpty, card != previous else { return .none }
    state.cards[id: card.id] = card
    state.isSavingEdit = true
    return .run { [apiClient, card] send in
      await send(
        .editSaveResponse(Result { try await apiClient.updateCard(card.id, card.text(.front), card.text(.back)) }, previous: previous)
      )
    }
  }

  /// Without a server URL and a token there is nothing to ask, so no request is made (spec 008).
  /// Every load shares one cancel id, so a slow response never overwrites a newer one; it also cancels a pending
  /// post-rating ladder, whose older stats would overwrite the load's.
  private func fetchQueue(_ state: inout State, afterRating: Bool = false) -> Effect<Action> {
    guard apiClient.isConfigured() else {
      state.phase = .notSetUp
      state.cards = []
      state.isRevealed = false
      return .merge(.cancel(id: CancelID.load), .cancel(id: CancelID.autoRefresh))
    }
    let load: Effect<Action> = .run { [apiClient] send in
      let queue = await Result {
        async let cards = apiClient.dueCards(100)
        async let stats = apiClient.stats()
        return try await Queue(cards: cards, stats: stats)
      }
      await send(.queueResponse(queue, afterRating: afterRating))
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
    return .merge(.cancel(id: CancelID.ladder), load)
  }
}

extension Card {
  static let photoField = "photo"
  static let nameField = "name"
  static let descriptionField = "description"

  /// The fields of `names` that have a value: an empty field isn't on the card.
  func shown(_ names: [String]) -> [String] {
    names.filter { fields[$0]?.isEmpty == false }
  }

  /// The prompt (`.front`) or answer (`.back`) text of a card with one text field per side (`canEditInline`).
  func text(_ side: StudyFeature.State.Field) -> String {
    fields[fieldName(side)] ?? ""
  }

  /// Updates the note's field and the card's rendered side together, as the server would.
  mutating func setText(_ text: String, for side: StudyFeature.State.Field) {
    fields[fieldName(side)] = text
    switch side {
    case .front: front = text
    case .back: back = text
    }
  }

  private func fieldName(_ side: StudyFeature.State.Field) -> String {
    side == .front ? prompt[0] : answer[0]
  }
}
