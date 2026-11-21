import APIClient
import CardEditorFeature
import ComposableArchitecture
import Foundation
import SettingsFeature

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
    @Presents var destination: Destination.State?

    public init() {}

    enum Phase: Equatable {
      case loading, loaded, offline
    }

    /// What to say instead of rows, if anything.
    var message: String? {
      switch phase {
      case .loading: nil
      case .offline: "Can't reach your deck"
      case .loaded where cards.isEmpty: query.isEmpty ? "No cards yet" : "No matches"
      case .loaded: nil
      }
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case addButtonTapped
    case settingsButtonTapped
    case rowTapped(Card.ID)
    case rowSwipedToDelete(Card.ID)
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
        return loadCards(matching: state.query, after: .seconds(0.3))

      case .onAppear:
        return loadCards(matching: state.query)

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

      case .cardsResponse(.failure):
        state.cards = []
        state.phase = .offline
        return .none

      case .deleteResponse(.success):
        // The swipe cancelled any load in flight, including a debounced search: catch up with the field.
        return .merge(
          loadCards(matching: state.query),
          .send(.delegate(.deckChanged))
        )

      case .deleteResponse(.failure):
        return loadCards(matching: state.query)

      case let .destination(.presented(.editor(.delegate(.saved(card))))):
        state.cards.updateOrInsert(card, at: 0)
        return .send(.delegate(.deckChanged))

      case .destination(.presented(.settings(.delegate(.serverChanged)))):
        return .merge(
          loadCards(matching: state.query),
          .send(.delegate(.deckChanged))
        )

      case .binding, .destination, .delegate:
        return .none
      }
    }
    .ifLet(\.$destination, action: \.destination)
  }

  /// Every load shares one cancel id, so a slow response never overwrites a newer one.
  private func loadCards(matching query: String, after delay: Duration = .zero) -> Effect<Action> {
    .run { [apiClient, clock] send in
      if delay > .zero {
        try await clock.sleep(for: delay)
      }
      await send(.cardsResponse(Result { try await apiClient.cards(query.isEmpty ? nil : query) }))
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }
}

extension DeckFeature.Destination.State: Equatable {}
