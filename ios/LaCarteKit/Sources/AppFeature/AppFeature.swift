import CardEditorFeature
import ComposableArchitecture
import DeckFeature
import DesignSystem
import SettingsFeature
import StudyFeature

/// Root feature: study is the home; the deck and "add from study" are sheets over it.
@Reducer
struct AppFeature {
  @Reducer
  enum Destination {
    case deck(DeckFeature)
    case addCard(CardEditorFeature)
  }

  @ObservableState
  struct State: Equatable {
    var study = StudyFeature.State()
    @Shared(.theme) var theme
    @Presents var destination: Destination.State?
  }

  enum Action {
    case study(StudyFeature.Action)
    case destination(PresentationAction<Destination.Action>)
  }

  var body: some ReducerOf<Self> {
    Scope(\.study, action: \.study) {
      StudyFeature()
    }
    Reduce { state, action in
      switch action {
      case .study(.delegate(.deckRequested)):
        state.destination = .deck(DeckFeature.State())
        return .none

      case .study(.delegate(.addCardRequested)):
        state.destination = .addCard(CardEditorFeature.State())
        return .none

      case .destination(.presented(.addCard(.delegate(.saved)))),
        .destination(.presented(.deck(.delegate(.deckChanged)))):
        return .send(.study(.deckChanged))

      case .study, .destination:
        return .none
      }
    }
    .ifLet(\.$destination, action: \.destination)
  }
}

extension AppFeature.Destination.State: Equatable {}
