import APIClient
import CardEditorFeature
import ComposableArchitecture
import Foundation
import SettingsFeature
import SwiftUI

/// Every card in the deck: search, swipe to delete, tap to edit, add (spec 002); hosts Settings (spec 003).
@Reducer
public struct DeckFeature {
  @Reducer
  public enum Destination {
    case editor(CardEditorFeature)
    case settings(SettingsFeature)
  }

  @ObservableState
  public struct State: Equatable {
    var cards: IdentifiedArrayOf<Card> = []
    var query = ""
    var phase: Phase = .loading
    /// Haptic trigger: bumps on every row deleted (spec 009a).
    var deletions = 0
    @Presents var destination: Destination.State?

    public init() {}

    enum Phase: Equatable {
      case loading, loaded, offline, notSetUp, unauthorized
    }

    enum Message: Equatable {
      case noCards, noMatches, offline, notSetUp, unauthorized

      var title: String {
        switch self {
        case .noCards: "No cards yet"
        case .noMatches: "No matches"
        case .offline: "Can't reach your deck"
        case .notSetUp: "Connect your deck"
        case .unauthorized: "Token rejected"
        }
      }

      var systemImage: String {
        switch self {
        case .noCards: "rectangle.stack"
        case .noMatches: "magnifyingglass"
        case .offline: "wifi.slash"
        case .notSetUp: "link"
        case .unauthorized: "key"
        }
      }
    }

    /// What to say instead of rows, if anything.
    var message: Message? {
      switch phase {
      case .loading: nil
      case .offline: .offline
      case .notSetUp: .notSetUp
      case .unauthorized: .unauthorized
      case .loaded where cards.isEmpty: query.isEmpty ? .noCards : .noMatches
      case .loaded: nil
      }
    }

    /// Only Settings can fix a missing or rejected token.
    var showsSettingsButton: Bool {
      phase == .notSetUp || phase == .unauthorized
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case addButtonTapped
    case settingsButtonTapped
    case rowTapped(Card.ID)
    case rowSwipedToDelete(Card.ID)
    case pulledToRefresh
    case scenePhaseChanged(ScenePhase)
    case cardsResponse(Result<[Card], any Error>)
    case deleteResponse(Result<Card.ID, any Error>)
    case destination(PresentationAction<Destination.Action>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case deckChanged
    }
  }

  @Dependency(\.apiClient) var apiClient
  @Dependency(\.continuousClock) var clock

  private enum CancelID { case load }

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.query):
        return loadCards(&state, after: .seconds(0.3))

      case .onAppear, .pulledToRefresh, .scenePhaseChanged(.active):
        return loadCards(&state)

      case .scenePhaseChanged:
        return .none

      case .addButtonTapped:
        state.destination = .editor(CardEditorFeature.State())
        return .none

      case .settingsButtonTapped:
        state.destination = .settings(SettingsFeature.State())
        return .none

      case let .rowTapped(id):
        guard let card = state.cards[id: id] else { return .none }
        state.destination = .editor(CardEditorFeature.State(card: card))
        return .none

      case let .rowSwipedToDelete(id):
        state.cards.remove(id: id)
        state.deletions += 1
        // A load still in flight may predate the delete and would bring the row back.
        return .merge(
          .cancel(id: CancelID.load),
          .run { [apiClient] send in
            await send(
              .deleteResponse(
                Result {
                  try await apiClient.deleteCard(id)
                  return id
                }
              )
            )
          }
        )

      case let .cardsResponse(.success(cards)):
        state.cards = IdentifiedArray(uniqueElements: cards)
        state.phase = .loaded
        return .none

      case let .cardsResponse(.failure(error)):
        state.cards = []
        state.phase = (error as? APIError)?.isUnauthorized == true ? .unauthorized : .offline
        return .none

      case .deleteResponse(.success):
        // The swipe cancelled any load in flight, including a debounced search: catch up with the field.
        return .merge(
          loadCards(&state),
          .send(.delegate(.deckChanged))
        )

      case .deleteResponse(.failure):
        return loadCards(&state)

      case let .destination(.presented(.editor(.delegate(.saved(card))))):
        state.cards.updateOrInsert(card, at: 0)
        return .send(.delegate(.deckChanged))

      case .destination(.presented(.settings(.delegate(.serverChanged)))):
        return .merge(
          loadCards(&state),
          .send(.delegate(.deckChanged))
        )

      // Closing Settings counts as saving it. Runs before `ifLet` clears the destination.
      case .destination(.dismiss) where state.destination?.is(\.settings) == true:
        return .merge(
          loadCards(&state),
          .send(.delegate(.deckChanged))
        )

      case .binding, .destination, .delegate:
        return .none
      }
    }
    .ifLet(\.$destination, action: \.destination)
  }

  /// Loads the cards matching the search field; without a server URL and a token, makes no request (spec 008).
  /// Every load shares one cancel id, so a slow response never overwrites a newer one.
  private func loadCards(_ state: inout State, after delay: Duration = .zero) -> Effect<Action> {
    guard apiClient.isConfigured() else {
      state.cards = []
      state.phase = .notSetUp
      return .cancel(id: CancelID.load)
    }
    let query = state.query
    return .run { [apiClient, clock] send in
      if delay > .zero {
        try await clock.sleep(for: delay)
      }
      await send(.cardsResponse(Result { try await apiClient.cards(query.isEmpty ? nil : query) }))
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }
}

extension DeckFeature.Destination.State: Equatable {}
