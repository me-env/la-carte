import Dependencies
import DependenciesMacros
import Foundation
import Security

/// The API bearer token, kept in the Keychain rather than `UserDefaults` because it is a secret (spec 003).
/// The item lives in the App Group's access group so the widget can read it too (spec 007).
@DependencyClient
public struct TokenStore: Sendable {
  public var load: @Sendable () -> String? = { nil }
  /// `nil` deletes the stored token.
  public var save: @Sendable (_ token: String?) throws -> Void
}

extension TokenStore: DependencyKey {
  public static let liveValue = TokenStore(
    load: {
      var query = keychainItem
      query[kSecReturnData] = true
      query[kSecMatchLimit] = kSecMatchLimitOne
      var result: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
        let data = result as? Data
      else { return nil }
      return String(decoding: data, as: UTF8.self)
    },
    save: { token in
      let deleted = SecItemDelete(keychainItem as CFDictionary)
      guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw KeychainError(status: deleted) }
      guard let token else { return }
      var item = keychainItem
      item[kSecValueData] = Data(token.utf8)
      item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
      let added = SecItemAdd(item as CFDictionary, nil)
      guard added == errSecSuccess else { throw KeychainError(status: added) }
    }
  )

  /// Moves the token saved before spec 007 (default access group) into the App Group's access group, once.
  /// Does nothing when the shared item already exists, so running it again is harmless.
  public static func migrateToSharedGroup() {
    guard let group = AppGroup.id, TokenStore.liveValue.load() == nil else { return }
    var legacy = keychainItem
    legacy[kSecAttrAccessGroup] = nil  // matches the legacy item only: the shared one doesn't exist
    moveLegacyItem(
      update: { SecItemUpdate(legacy as CFDictionary, [kSecAttrAccessGroup: group] as CFDictionary) },
      copy: {
        var query = legacy
        query[kSecReturnData] = true
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let attributes = result as? [CFString: Any],
          let data = attributes[kSecValueData] as? Data,
          let legacyGroup = attributes[kSecAttrAccessGroup] as? String
        else { return nil }
        return (data, legacyGroup)
      },
      add: { data in
        var item = keychainItem
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil)
      },
      delete: { legacyGroup in
        var item = legacy
        item[kSecAttrAccessGroup] = legacyGroup
        SecItemDelete(item as CFDictionary)
      }
    )
  }

  /// Tries the atomic in-place move first; if the Keychain refuses it, copies the item and deletes the legacy one
  /// only once the copy is stored, so a failure never loses the token.
  static func moveLegacyItem(
    update: () -> OSStatus,
    copy: () -> (data: Data, accessGroup: String)?,
    add: (Data) -> OSStatus,
    delete: (String) -> Void
  ) {
    let updated = update()
    guard updated != errSecSuccess, updated != errSecItemNotFound, let legacy = copy() else { return }
    if add(legacy.data) == errSecSuccess {
      delete(legacy.accessGroup)
    }
  }

  public static let testValue = TokenStore()

  public static var previewValue: TokenStore {
    let token = LockIsolated<String?>(nil)
    return TokenStore(load: { token.value }, save: { token.setValue($0) })
  }
}

extension DependencyValues {
  public var tokenStore: TokenStore {
    get { self[TokenStore.self] }
    set { self[TokenStore.self] = newValue }
  }
}

private let service = "la-carte"
private let account = "api-token"

private var keychainItem: [CFString: Any] {
  var item: [CFString: Any] = [
    kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
  ]
  item[kSecAttrAccessGroup] = AppGroup.id
  return item
}

struct KeychainError: Error {
  var status: OSStatus
}
