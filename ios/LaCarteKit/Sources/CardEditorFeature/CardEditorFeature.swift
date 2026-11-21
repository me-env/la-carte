import APIClient
import ComposableArchitecture
import Foundation

/// Adds a new card or fixes an existing card's text; shared by the deck and the study screen (spec 002).
@Reducer
public struct CardEditorFeature {
  @ObservableState
  public struct State: Equatable {
    let card: Card?
    var front: String
    var back: String
    var isSaving = false
    var saveFailed = false
    /// A plain flag rather than `ConfirmationDialogState`, whose buttons can't carry accessibility identifiers.
    var isDiscardDialogPresented = false

    public init(card: Card? = nil) {
      self.card = card
      self.front = card?.front ?? ""
      self.back = card?.back ?? ""
    }

    var canSave: Bool {
      !isSaving && !front.trimmed.isEmpty && !back.trimmed.isEmpty
    }

    var hasChanges: Bool {
      front.trimmed != (card?.front ?? "") || back.trimmed != (card?.back ?? "")
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case saveButtonTapped
    case closeButtonTapped
    case discardTapped
    case saveResponse(Result<Card, any Error>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case saved(Card)
    }
  }

  @Dependency(\.apiClient) var apiClient
  @Dependency(\.dismiss) var dismiss

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .saveButtonTapped:
        guard state.canSave else { return .none }
        state.isSaving = true
        state.saveFailed = false
        let (id, front, back) = (state.card?.id, state.front.trimmed, state.back.trimmed)
        return .run { [apiClient] send in
          await send(
            .saveResponse(
              Result {
                if let id {
                  try await apiClient.updateCard(id, front, back)
                } else {
                  try await apiClient.addCard(front, back)
                }
              }
            )
          )
        }

      case .closeButtonTapped:
        guard state.hasChanges else { return .run { [dismiss] _ in await dismiss() } }
        state.isDiscardDialogPresented = true
        return .none

      case .discardTapped:
        return .run { [dismiss] _ in await dismiss() }

      case let .saveResponse(.success(card)):
        return .run { [dismiss] send in
          await send(.delegate(.saved(card)))
          await dismiss()
        }

      case .saveResponse(.failure):
        state.isSaving = false
        state.saveFailed = true
        return .none

      case .binding, .delegate:
        return .none
      }
    }
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
