import Foundation
import Testing

@testable import APIClient

/// Spec 007 #11-#12: settings move to the App Group suite once, and the live client reads the URL from there.
struct AppGroupTests {
  let oldName = "lacarte.tests.old.\(UUID())"
  let newName = "lacarte.tests.group.\(UUID())"

  private func withSuites(_ body: (_ old: UserDefaults, _ new: UserDefaults) throws -> Void) throws {
    defer {
      UserDefaults.standard.removePersistentDomain(forName: oldName)
      UserDefaults.standard.removePersistentDomain(forName: newName)
    }
    try body(try #require(UserDefaults(suiteName: oldName)), try #require(UserDefaults(suiteName: newName)))
  }

  private func migrate(_ old: UserDefaults, _ new: UserDefaults, _ keys: [String] = ["apiURL", "theme"]) {
    AppGroup.migrate(keys, from: old, domain: oldName, to: new, suite: newName)
  }

  @Test func migrationMovesValuesTheSuiteDoesNotHave() throws {
    try withSuites { old, new in
      old.set("https://cards.example.com", forKey: "apiURL")
      old.set("forest", forKey: "theme")
      new.set("light", forKey: "theme")

      migrate(old, new)

      #expect(new.string(forKey: "apiURL") == "https://cards.example.com")
      #expect(new.string(forKey: "theme") == "light")
      #expect(old.object(forKey: "apiURL") == nil)
      #expect(old.object(forKey: "theme") == nil)
    }
  }

  @Test func runningTheMigrationTwiceChangesNothing() throws {
    try withSuites { old, new in
      old.set("https://cards.example.com", forKey: "apiURL")

      migrate(old, new)
      new.set("https://other.example.com", forKey: "apiURL")
      migrate(old, new)

      #expect(new.string(forKey: "apiURL") == "https://other.example.com")
      #expect(new.object(forKey: "theme") == nil)
    }
  }

  /// Like `-theme forest`: a value the suite only sees from a non-persistent domain doesn't block the migration.
  @Test func aVolatileValueInTheSuiteDoesNotCountAsStored() throws {
    let key = "lacarte.tests.key.\(UUID())"
    try withSuites { old, new in
      old.set("stored", forKey: key)
      new.register(defaults: [key: "volatile"])

      migrate(old, new, [key])

      #expect(new.persistentDomain(forName: newName)?[key] as? String == "stored")
      #expect(old.persistentDomain(forName: oldName)?[key] == nil)
    }
  }

  @Test func theLiveClientReadsTheURLFromTheSuite() throws {
    try withSuites { _, suite in
      let client = APIClient.live(environment: ["LA_CARTE_API_TOKEN": "s3"]) { [newName] in
        UserDefaults(suiteName: newName)?.string(forKey: APIClient.urlDefaultsKey)
      }
      #expect(!client.isConfigured())

      suite.set("https://cards.example.com", forKey: APIClient.urlDefaultsKey)
      #expect(client.isConfigured())
    }
  }
}
