import ComposableArchitecture
import DeckFeature
import DesignSystem
import NoteEditorFeature
import SettingsFeature
import StudyFeature

/// Root feature: study is the home; the deck, "add from study" and Settings (spec 008) are sheets over it.
@Reducer
struct AppFeature {
  @Reducer
  enum Destination {
    case deck(DeckFeature)
    case addNote(NoteEditorFeature)
    case settings(SettingsFeature)
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
        state.destination = .addNote(NoteEditorFeature.State())
        return .none

      case .study(.delegate(.settingsRequested)):
        state.destination = .settings(SettingsFeature.State())
        return .none

      case .destination(.presented(.addNote(.delegate(.saved)))),
        .destination(.presented(.deck(.delegate(.deckChanged)))),
        .destination(.presented(.settings(.delegate(.serverChanged)))):
        return .send(.study(.deckChanged))

      // Closing Settings counts as saving it. Runs before `ifLet` clears the destination.
      case .destination(.dismiss) where state.destination?.is(\.settings) == true:
        return .send(.study(.deckChanged))

      case .study, .destination:
        return .none
      }
    }
    .ifLet(\.$destination, action: \.destination)
  }
}

extension AppFeature.Destination.State: Equatable {}
