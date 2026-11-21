import CardEditorFeature
import ComposableArchitecture
import DeckFeature
import DeckWidget
import DesignSystem
import SettingsFeature
import StudyFeature
import SwiftUI
import WidgetKit

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
  @Environment(\.scenePhase) private var scenePhase

  public init() {
    Theme.tintSearchFields()
  }

  public var body: some View {
    Group {
      #if DEBUG
        switch galleryScreen {
        case "design-system": DesignSystemGallery()
        case "widget": DeckWidgetGallery()
        default: AppView(store: store)
        }
      #else
        AppView(store: store)
      #endif
    }
    .appTheme(store.theme)
    // Reviews, edits, server and theme changes all happen in the app: refresh the widget when leaving it.
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { WidgetCenter.shared.reloadAllTimelines() }
    }
  }

  #if DEBUG
    /// `LA_CARTE_SCREEN=design-system` or `widget` (debug builds only) opens a gallery for UI tests.
    private var galleryScreen: String? {
      ProcessInfo.processInfo.environment["LA_CARTE_SCREEN"]
    }
  #endif
}

#Preview {
  RootView()
}
