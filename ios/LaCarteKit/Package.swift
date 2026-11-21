// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "LaCarteKit",
  platforms: [.iOS(.v26)],
  products: [
    .library(name: "AppFeature", targets: ["AppFeature"])
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
        "CardEditorFeature",
        "DeckFeature",
        "DesignSystem",
        "SettingsFeature",
        "StudyFeature",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(
      name: "AppFeatureTests",
      dependencies: ["AppFeature", "APIClient", "CardEditorFeature", "DeckFeature", "SettingsFeature", "StudyFeature"]
    ),
    .target(
      name: "CardEditorFeature",
      dependencies: [
        "APIClient",
        "DesignSystem",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(name: "CardEditorFeatureTests", dependencies: ["CardEditorFeature", "APIClient"]),
    .target(
      name: "DeckFeature",
      dependencies: [
        "APIClient",
        "CardEditorFeature",
        "DesignSystem",
        "SettingsFeature",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(
      name: "DeckFeatureTests",
      dependencies: ["DeckFeature", "APIClient", "CardEditorFeature", "SettingsFeature"]
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

    // MARK: UI foundation (no TCA)
    .target(name: "DesignSystem"),
    .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
  ],
  swiftLanguageModes: [.v6]
)
