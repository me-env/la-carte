import AppFeature
import SwiftUI

@main
struct LaCarteApp: App {
  init() {
    bootstrap()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
