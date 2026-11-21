import APIClient
import ComposableArchitecture
import DesignSystem

/// Points `@Shared(.appStorage)` at the App Group suite and moves pre-widget settings there (spec 007).
/// The app shell calls it once, in `App.init`, before the first store exists.
public func bootstrap() {
  AppGroup.migrate([APIClient.urlDefaultsKey, AppTheme.storageKey])
  TokenStore.migrateToSharedGroup()
  prepareDependencies {
    $0.defaultAppStorage = AppGroup.defaults
  }
}
