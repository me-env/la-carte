import APIClient
import ComposableArchitecture
import Foundation

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
      case loading, studying, caughtUp(nextDue: Date?), offline
    }
  }

  public enum Action {
    case onAppear
    case revealTapped
    case ratingTapped(Rating)
    case retryButtonTapped
    case deckButtonTapped
    case addButtonTapped
    case deckChanged
    case cardsResponse(Result<[Card], any Error>)
    case statsResponse(Result<DeckStats, any Error>)
    case reviewResponse(Result<Card, any Error>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case deckRequested, addCardRequested
    }
  }

  @Dependency(\.apiClient) var apiClient

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear, .deckChanged:
        return fetchDueCards()

      case .retryButtonTapped:
        state.phase = .loading
        return fetchDueCards()

      case .revealTapped:
        state.isRevealed = true
        return .none

      case let .ratingTapped(rating):
        guard !state.isReviewing, let card = state.cards.first else { return .none }
        state.isReviewing = true
        return .run { [apiClient] send in
          await send(.reviewResponse(Result { try await apiClient.review(card.id, rating) }))
        }

      case .deckButtonTapped:
        return .send(.delegate(.deckRequested))

      case .addButtonTapped:
        return .send(.delegate(.addCardRequested))

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
        return state.cards.isEmpty ? fetchDueCards() : .none

      case .cardsResponse(.failure), .statsResponse(.failure), .reviewResponse(.failure):
        state.isReviewing = false
        state.phase = .offline
        return .none

      case .delegate:
        return .none
      }
    }
  }

  private func fetchDueCards() -> Effect<Action> {
    .run { [apiClient] send in
      await send(.cardsResponse(Result { try await apiClient.dueCards(100) }))
    }
  }
}
