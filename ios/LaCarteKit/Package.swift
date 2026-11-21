// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "LaCarteKit",
  platforms: [.iOS(.v26)],
  products: [
    .library(name: "AppFeature", targets: ["AppFeature"]),
    .library(name: "DeckWidget", targets: ["DeckWidget"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      from: "1.26.2",
      traits: ["ComposableArchitecture2Deprecations"]
    ),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.17.2"),
  ],
  targets: [
    // MARK: Features (one module per feature, all built with TCA)
    .target(
      name: "AppFeature",
      dependencies: [
        "DeckFeature",
        "DeckWidget",
        "DesignSystem",
        "NoteEditorFeature",
        "SettingsFeature",
        "StudyFeature",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(
      name: "AppFeatureTests",
      dependencies: ["AppFeature", "APIClient", "DeckFeature", "NoteEditorFeature", "SettingsFeature", "StudyFeature"]
    ),
    .target(
      name: "NoteEditorFeature",
      dependencies: [
        "APIClient",
        "DesignSystem",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(name: "NoteEditorFeatureTests", dependencies: ["NoteEditorFeature", "APIClient"]),
    .target(
      name: "DeckFeature",
      dependencies: [
        "APIClient",
        "DesignSystem",
        "NoteEditorFeature",
        "SettingsFeature",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(
      name: "DeckFeatureTests",
      dependencies: ["DeckFeature", "APIClient", "NoteEditorFeature", "SettingsFeature"]
    ),
    .target(
      name: "SettingsFeature",
      dependencies: [
        "APIClient",
        "DesignSystem",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(name: "SettingsFeatureTests", dependencies: ["SettingsFeature", "APIClient", "DesignSystem"]),
    .target(
      name: "StudyFeature",
      dependencies: [
        "APIClient",
        "DesignSystem",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(name: "StudyFeatureTests", dependencies: ["StudyFeature", "APIClient"]),

    // MARK: Clients (dependencies, no UI, no TCA)
    .target(
      name: "APIClient",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
      ]
    ),
    .testTarget(name: "APIClientTests", dependencies: ["APIClient"]),

    // MARK: Widget (plain SwiftUI + WidgetKit, no TCA; spec 007)
    .target(name: "DeckWidget", dependencies: ["APIClient", "DesignSystem"]),
    .testTarget(name: "DeckWidgetTests", dependencies: ["DeckWidget", "APIClient"]),

    // MARK: UI foundation (no TCA)
    .target(name: "DesignSystem"),
    .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
  ],
  swiftLanguageModes: [.v6]
)
