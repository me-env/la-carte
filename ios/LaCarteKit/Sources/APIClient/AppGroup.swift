import Foundation

/// The App Group shared by the app and its widget (spec 007): settings live in its `UserDefaults` suite and the
/// token in its keychain access group, so the widget reads the same deck without its own Settings.
public enum AppGroup {
  /// `group.$(LA_CARTE_BUNDLE_ID_PREFIX).app`, from the `LaCarteAppGroup` Info.plist key of the app and the widget.
  /// `nil` where there is no such key (unit tests), which falls back to the app's own storage.
  public static let id = Bundle.main.object(forInfoDictionaryKey: "LaCarteAppGroup") as? String

  /// The suite both targets read and write; `.standard` when there is no App Group. Instances of one suite share
  /// their storage in-process, so a fresh one per call is fine (and `UserDefaults` isn't `Sendable`).
  public static var defaults: UserDefaults {
    id.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  /// Moves settings stored before spec 007 from the app's own defaults into the suite. Run once at launch, before
  /// the first store; running it again changes nothing.
  public static func migrate(_ keys: [String]) {
    guard id != nil, let domain = Bundle.main.bundleIdentifier else { return }
    migrate(keys, from: .standard, domain: domain, to: defaults)
  }

  /// Copies each key to `new` unless it already has a value, then removes it from `old`. Reads `old`'s persistent
  /// `domain` only, so a launch argument such as `-theme forest` is never written to disk.
  static func migrate(_ keys: [String], from old: UserDefaults, domain: String, to new: UserDefaults) {
    let stored = old.persistentDomain(forName: domain) ?? [:]
    for key in keys {
      guard let value = stored[key] else { continue }
      if new.object(forKey: key) == nil {
        new.set(value, forKey: key)
      }
      old.removeObject(forKey: key)
    }
  }
}
