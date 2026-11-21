import Dependencies
import DependenciesMacros
import Foundation
import Security

/// The API bearer token, kept in the Keychain rather than `UserDefaults` because it is a secret (spec 003).
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

private var keychainItem: [CFString: Any] {
  [kSecClass: kSecClassGenericPassword, kSecAttrService: "la-carte", kSecAttrAccount: "api-token"]
}

struct KeychainError: Error {
  var status: OSStatus
}
