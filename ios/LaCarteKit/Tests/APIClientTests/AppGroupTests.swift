import Foundation
import Testing

@testable import APIClient

/// Spec 007 #11-#12: settings move to the App Group suite once, and the live client reads the URL from there.
struct AppGroupTests {
  let oldName = "lacarte.tests.old.\(UUID())"
  let newName = "lacarte.tests.group.\(UUID())"

  @Test func migrationMovesValuesTheSuiteDoesNotHave() throws {
    let old = try #require(UserDefaults(suiteName: oldName))
    let new = try #require(UserDefaults(suiteName: newName))
    old.set("https://cards.example.com", forKey: "apiURL")
    old.set("forest", forKey: "theme")
    new.set("light", forKey: "theme")

    AppGroup.migrate(["apiURL", "theme"], from: old, domain: oldName, to: new)

    #expect(new.string(forKey: "apiURL") == "https://cards.example.com")
    #expect(new.string(forKey: "theme") == "light")
    #expect(old.object(forKey: "apiURL") == nil)
    #expect(old.object(forKey: "theme") == nil)
  }

  @Test func runningTheMigrationTwiceChangesNothing() throws {
    let old = try #require(UserDefaults(suiteName: oldName))
    let new = try #require(UserDefaults(suiteName: newName))
    old.set("https://cards.example.com", forKey: "apiURL")

    AppGroup.migrate(["apiURL", "theme"], from: old, domain: oldName, to: new)
    let migrated = new.dictionaryRepresentation().filter { ["apiURL", "theme"].contains($0.key) }
    new.set("https://other.example.com", forKey: "apiURL")
    AppGroup.migrate(["apiURL", "theme"], from: old, domain: oldName, to: new)

    #expect(migrated.count == 1)
    #expect(new.string(forKey: "apiURL") == "https://other.example.com")
    #expect(new.object(forKey: "theme") == nil)
  }

  @Test func theLiveClientReadsTheURLFromTheSuite() throws {
    let suite = try #require(UserDefaults(suiteName: newName))
    let client = APIClient.live(environment: ["LA_CARTE_API_TOKEN": "s3"]) { [newName] in
      UserDefaults(suiteName: newName)?.string(forKey: APIClient.urlDefaultsKey)
    }
    #expect(!client.isConfigured())

    suite.set("https://cards.example.com", forKey: APIClient.urlDefaultsKey)
    #expect(client.isConfigured())
  }
}
