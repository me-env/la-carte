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

    public init() {}

    /// The side of the revealed card being edited in place (spec 010).
    public enum Field: Hashable, Sendable {
      case front, back
    }

    enum Phase: Equatable {
      case loading, studying, caughtUp(nextDue: Date?), offline, notSetUp, unauthorized
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case revealTapped
    case cardTapped
    case textDoubleTapped(State.Field)
    case editEnded
    case ratingTapped(Rating)
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

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.draft):
        // A vertical field may type return instead of submitting it: a trailing newline ends the edit.
        guard state.draft.hasSuffix("\n") else { return .none }
        state.draft.removeLast()
        return endEdit(&state)

      case .binding:
        return .none

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
          let card = state.cards.first
        else { return .none }
        state.editing = field
        state.draft = field == .front ? card.front : card.back
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

      case .deckButtonTapped:
        return .merge(endEdit(&state), .send(.delegate(.deckRequested)))

      case .addButtonTapped:
        return .merge(endEdit(&state), .send(.delegate(.addCardRequested)))

      case .openSettingsTapped:
        return .send(.delegate(.settingsRequested))

      case let .cardsResponse(.success(cards)):
        if cards.first?.id != state.cards.first?.id {
          state.isRevealed = false
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
        state.phase = (error as? APIError)?.isUnauthorized == true ? .unauthorized : .offline
        return .none

      case .delegate:
        return .none
      }
    }
  }

  /// Saves the edited side optimistically: the trimmed text shows at once and the server's card replaces it.
  /// An unchanged or blank text just ends the edit. Idempotent, since focus loss can follow Done.
  private func endEdit(_ state: inout State) -> Effect<Action> {
    guard let field = state.editing, let previous = state.cards.first else { return .none }
    state.editing = nil
    let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    var card = previous
    switch field {
    case .front: card.front = text
    case .back: card.back = text
    }
    guard !text.isEmpty, card != previous else { return .none }
    state.cards[id: card.id] = card
    state.isSavingEdit = true
    return .run { [apiClient, card] send in
      await send(
        .editSaveResponse(Result { try await apiClient.updateCard(card.id, card.front, card.back) }, previous: previous)
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
