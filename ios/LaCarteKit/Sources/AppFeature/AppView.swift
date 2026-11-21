import CardEditorFeature
import ComposableArchitecture
import DeckFeature
import DesignSystem
import SettingsFeature
import StudyFeature
import SwiftUI

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    StudyView(store: store.scope(\.study, action: \.study))
      .sheet(item: $store.scope(\.$destination, action: \.destination).deck) { deckStore in
        DeckView(store: deckStore)
      }
      .sheet(item: $store.scope(\.$destination, action: \.destination).addCard) { editorStore in
        CardEditorView(store: editorStore)
      }
      .sheet(item: $store.scope(\.$destination, action: \.destination).settings) { settingsStore in
        SettingsView(store: settingsStore)
      }
  }
}

/// Entry point used by the app target, which stays a thin shell.
public struct RootView: View {
  @State private var store = Store(initialState: AppFeature.State()) { AppFeature() }

  public init() {}

  public var body: some View {
    Group {
      if showsDesignSystem {
        DesignSystemGallery()
      } else {
        AppView(store: store)
      }
    }
    .appTheme(store.theme)
  }

  /// `LA_CARTE_SCREEN=design-system` (debug builds only) opens the gallery for UI tests.
  private var showsDesignSystem: Bool {
    #if DEBUG
      ProcessInfo.processInfo.environment["LA_CARTE_SCREEN"] == "design-system"
    #else
      false
    #endif
  }
}

#Preview {
  RootView()
}
