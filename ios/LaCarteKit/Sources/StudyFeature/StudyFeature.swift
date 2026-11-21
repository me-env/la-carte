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

    public init() {}

    enum Phase: Equatable {
      case loading, studying, caughtUp(nextDue: Date?), offline, notSetUp, unauthorized
    }
  }

  public enum Action {
    case onAppear
    case revealTapped
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
    Reduce { state, action in
      switch action {
      case .onAppear, .deckChanged:
        return fetchDueCards(&state)

      case .pulledToRefresh, .scenePhaseChanged(.active):
        // The review's response updates the queue; a list fetched meanwhile could bring the rated card back.
        guard !state.isReviewing else { return .none }
        return fetchDueCards(&state)

      case .scenePhaseChanged:
        return .none

      case .retryButtonTapped:
        state.phase = .loading
        return fetchDueCards(&state)

      case .revealTapped:
        state.isRevealed = true
        return .none

      case let .ratingTapped(rating):
        guard !state.isReviewing, let card = state.cards.first else { return .none }
        state.isReviewing = true
        // A load in flight may predate the review and would bring the rated card back.
        return .merge(
          .cancel(id: CancelID.load),
          .run { [apiClient] send in
            await send(.reviewResponse(Result { try await apiClient.review(card.id, rating) }))
          }
        )

      case .deckButtonTapped:
        return .send(.delegate(.deckRequested))

      case .addButtonTapped:
        return .send(.delegate(.addCardRequested))

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
