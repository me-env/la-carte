import APIClient
import AskAIClient
import ComposableArchitecture
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
    /// The continuous ease value 0...1 while a rating drag is held; nil = no ring (spec 011).
    var swipeEase: Double?
    var isReportMenuShown = false
    var isReportCommentShown = false
    var reportComment = ""
    /// Shown in the counter slot: a report's or a copy's outcome (specs 015, 016).
    var notice: Notice?
    /// Cards whose broken photo was reported this session: sent once, and never served again (spec 015 #13-15).
    var reportedBrokenPhotos: Set<Card.ID> = []

    /// What releasing the drag now would send.
    var swipeRating: Rating? { swipeEase.flatMap(StudyFeature.rating(forEase:)) }

    /// The buttons can be tapped, a drag can rate, and VoiceOver offers the ratings.
    var canRate: Bool {
      phase == .studying && isRevealed && editing == nil && !isReviewing
    }

    /// The double-tap menu (report, ask) is offered exactly when the card can be rated.
    var canReport: Bool { canRate }

    /// Inline edit (010) needs one text field on each side; photo and multi-field cards use the deck editor (014d).
    var canEditInline: Bool {
      guard let card = cards.first else { return false }
      return card.prompt.count == 1 && card.answer.count == 1 && !card.prompt.contains(Card.photoField)
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

    enum Notice: Equatable {
      case reported, failed, copied
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
    case pulledToRefresh
    case scenePhaseChanged(ScenePhase)
    case cardsResponse(Result<[Card], any Error>)
    case statsResponse(Result<DeckStats, any Error>)
    case reviewResponse(Result<Card, any Error>)
    case editSaveResponse(Result<Card, any Error>, previous: Card)
    case cardDoubleTapped
    case askTapped
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

  @Dependency(\.apiClient) var apiClient
  @Dependency(\.askAI) var askAI
  @Dependency(\.continuousClock) var clock

  private enum CancelID { case load, notice }

  public init() {}

  /// The drag's scale: the ring's radius as a fraction of the card's width.
  static let ringRadius = 0.25

  /// The ease value for a horizontal drag of `fraction` card widths: 0.5 at touch-down, 0 or 1 on the ring.
  static func ease(forSwipe fraction: Double) -> Double {
    min(max(0.5 + fraction / (2 * ringRadius), 0), 1)
  }

  /// FSRS takes four grades; the middle band is a dead zone so going back to the start cancels.
  static func rating(forEase ease: Double) -> Rating? {
    switch ease {
    case ...0.125: .again
    case ...0.35: .hard
    case ..<0.65: nil
    case ..<0.875: .good
    default: .easy
    }
  }

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
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
        return fetchDueCards(&state)

      case .pulledToRefresh, .scenePhaseChanged(.active):
        // The review's or the edit's response updates the queue; a list fetched meanwhile could undo it.
        // While editing, a new list could replace the card under the user's fingers.
        guard !state.isReviewing, state.editing == nil, !state.isSavingEdit else { return .none }
        return fetchDueCards(&state)

      case .scenePhaseChanged:
        return .none

      case .retryButtonTapped:
        state.phase = .loading
        return fetchDueCards(&state)

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
        return review(rating, state: &state)

      case .deckButtonTapped:
        return .merge(endEdit(&state), .send(.delegate(.deckRequested)))

      case .addButtonTapped:
        return .merge(endEdit(&state), .send(.delegate(.addCardRequested)))

      case .openSettingsTapped:
        return .send(.delegate(.settingsRequested))

      case var .cardsResponse(.success(cards)):
        // The report may not have landed yet (or failed): a skipped card must not come back.
        cards.removeAll { $0.id != state.cards.first?.id && state.reportedBrokenPhotos.contains($0.id) }
        if cards.first?.id != state.cards.first?.id {
          state.isRevealed = false
          state.swipeEase = nil
        }
        state.cards = IdentifiedArray(uniqueElements: cards)
        guard cards.isEmpty else {
          state.phase = .studying
          return .none
        }
        return fetchStats()

      case let .statsResponse(.success(stats)):
        state.phase = stats.total == 0 ? .empty : .caughtUp(nextDue: stats.nextDue)
        return .none

      case let .reviewResponse(.success(card)):
        state.isReviewing = false
        state.isRevealed = false
        state.cards.remove(id: card.id)
        return state.cards.isEmpty ? fetchDueCards(&state) : .none

      case let .cardsResponse(.failure(error)), let .statsResponse(.failure(error)),
        let .reviewResponse(.failure(error)):
        state.isReviewing = false
        // The card and its pan leave the screen, so a held drag may never send its release.
        state.swipeEase = nil
        state.phase = (error as? APIError)?.isUnauthorized == true ? .unauthorized : .offline
        return .none

      case .cardDoubleTapped:
        guard state.canReport else { return .none }
        state.isReportMenuShown = true
        return .none

      case .askTapped:
        guard state.canReport, let card = state.cards.first else { return .none }
        state.notice = .copied
        let text = AskText.make(for: card)
        return .merge(.run { [askAI] _ in askAI.copy(text) }, expireNotice())

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
        return .merge(expireNotice(), state.cards.isEmpty ? fetchDueCards(&state) : .none)

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
          return state.cards.isEmpty && state.phase == .studying ? fetchDueCards(&state) : .none
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
        return state.cards.isEmpty && state.phase == .loading ? fetchDueCards(&state) : .none

      case let .brokenPhotoReportResponse(.failure, cardID):
        // Not held by the API, so it may come back on the next load; refetching now would only loop on it.
        state.reportedBrokenPhotos.remove(cardID)
        guard state.cards.isEmpty, state.phase == .loading else { return .none }
        return fetchStats().cancellable(id: CancelID.load, cancelInFlight: true)

      case .delegate:
        return .none
      }
    }
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

  private func fetchStats() -> Effect<Action> {
    .run { [apiClient] send in
      await send(.statsResponse(Result { try await apiClient.stats() }))
    }
  }

  private func expireNotice() -> Effect<Action> {
    .run { [clock] send in
      try await clock.sleep(for: .seconds(2))
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
  /// Every load shares one cancel id, so a slow response never overwrites a newer one.
  private func fetchDueCards(_ state: inout State) -> Effect<Action> {
    guard apiClient.isConfigured() else {
      state.phase = .notSetUp
      state.cards = []
      state.isRevealed = false
      return .cancel(id: CancelID.load)
    }
    return .run { [apiClient] send in
      await send(.cardsResponse(Result { try await apiClient.dueCards(100) }))
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }
}

extension Card {
  static let photoField = "photo"

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
