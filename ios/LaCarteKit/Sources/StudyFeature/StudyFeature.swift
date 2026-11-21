import APIClient
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

    /// What releasing the drag now would send.
    var swipeRating: Rating? { swipeEase.flatMap(StudyFeature.rating(forEase:)) }

    /// The buttons can be tapped, a drag can rate, and VoiceOver offers the ratings.
    var canRate: Bool {
      phase == .studying && isRevealed && editing == nil && !isReviewing
    }

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

    enum Phase: Equatable {
      case loading, studying, caughtUp(nextDue: Date?), offline, notSetUp, unauthorized
    }
  }

  public enum Action {
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
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case deckRequested, addCardRequested, settingsRequested
    }
  }

  @Dependency(\.apiClient) var apiClient

  private enum CancelID { case load }

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
    Reduce { state, action in
      switch action {
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
        if state.editing != nil { return endEdit(&state) }
        state.isRevealed = true
        return .none

      case let .textDoubleTapped(field):
        guard state.isRevealed, state.editing == nil, !state.isSavingEdit, state.phase == .studying,
          state.canEditInline, let card = state.cards.first
        else { return .none }
        state.editing = field
        state.draft = card.text(field)
        state.editFailed = false
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

      case let .cardsResponse(.success(cards)):
        if cards.first?.id != state.cards.first?.id {
          state.isRevealed = false
          state.swipeEase = nil
        }
        state.cards = IdentifiedArray(uniqueElements: cards)
        guard cards.isEmpty else {
          state.phase = .studying
          return .none
        }
        return .run { [apiClient] send in
          await send(.statsResponse(Result { try await apiClient.stats() }))
        }

      case let .statsResponse(.success(stats)):
        state.phase = .caughtUp(nextDue: stats.nextDue)
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

      case .delegate:
        return .none
      }
    }
  }

  private func review(_ rating: Rating, state: inout State) -> Effect<Action> {
    guard !state.isReviewing, let card = state.cards.first else { return .none }
    state.isReviewing = true
    state.editFailed = false
    // A load in flight may predate the review and would bring the rated card back.
    return .merge(
      .cancel(id: CancelID.load),
      .run { [apiClient] send in
        await send(.reviewResponse(Result { try await apiClient.review(card.id, rating) }))
      }
    )
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
