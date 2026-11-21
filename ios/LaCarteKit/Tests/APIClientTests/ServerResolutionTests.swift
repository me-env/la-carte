import Dependencies
import Foundation
import Testing

@testable import APIClient

/// Spec 008 #1-#3 (supersedes 003 #6): launch env > value stored by Settings > none, resolved on every request.
struct ServerResolutionTests {
  @Test func launchEnvURLWinsOverTheStoredOne() {
    let url = APIClient.resolvedBaseURL(
      environment: ["LA_CARTE_API_URL": "http://127.0.0.1:8123"],
      stored: "https://cards.example.com"
    )
    #expect(url == URL(string: "http://127.0.0.1:8123"))
  }

  @Test func storedURLIsUsedWhenItIsHTTP() {
    #expect(
      APIClient.resolvedBaseURL(environment: [:], stored: "https://cards.example.com")
        == URL(string: "https://cards.example.com")
    )
    #expect(
      APIClient.resolvedBaseURL(environment: ["LA_CARTE_API_URL": ""], stored: " http://10.0.0.2:8000 ")
        == URL(string: "http://10.0.0.2:8000")
    )
  }

  @Test func missingOrInvalidURLMeansNoServer() {
    for stored in [nil, "", "   ", "ftp://x", "localhost", "cards.example.com"] {
      #expect(APIClient.resolvedBaseURL(environment: [:], stored: stored) == nil)
      #expect(APIClient.resolvedBaseURL(environment: ["LA_CARTE_API_URL": stored ?? ""], stored: nil) == nil)
    }
  }

  @Test func launchEnvTokenWinsWithoutReadingTheKeychain() {
    let token = APIClient.resolvedToken(environment: ["LA_CARTE_API_TOKEN": "env"]) {
      Issue.record("stored token read although the launch env sets one")
      return "stored"
    }
    #expect(token == "env")
  }

  @Test func storedTokenIsUsedOtherwiseAndEmptyMeansNone() {
    #expect(APIClient.resolvedToken(environment: [:]) { "stored" } == "stored")
    #expect(APIClient.resolvedToken(environment: ["LA_CARTE_API_TOKEN": ""]) { "stored" } == "stored")
    #expect(APIClient.resolvedToken(environment: [:]) { nil } == nil)
    #expect(APIClient.resolvedToken(environment: [:]) { "" } == nil)
  }

  @Test func configuredOnlyWithAURLAndATokenReadAtCallTime() {
    let environment = LockIsolated<[String: String]>([:])
    let storedURL = LockIsolated<String?>(nil)
    let storedToken = LockIsolated<String?>(nil)
    let client = APIClient.live(
      baseURL: { APIClient.resolvedBaseURL(environment: environment.value, stored: storedURL.value) },
      token: { APIClient.resolvedToken(environment: environment.value) { storedToken.value } }
    )

    #expect(!client.isConfigured())
    storedURL.setValue("https://cards.example.com")
    #expect(!client.isConfigured())
    storedToken.setValue("s3")
    #expect(client.isConfigured())
    storedToken.setValue("")
    #expect(!client.isConfigured())
    storedURL.setValue(nil)
    storedToken.setValue("s3")
    #expect(!client.isConfigured())
    storedToken.setValue(nil)
    environment.setValue(["LA_CARTE_API_URL": "http://127.0.0.1:8123", "LA_CARTE_API_TOKEN": "env"])
    #expect(client.isConfigured())
  }

  @Test func theMockDeckIsAlwaysConfigured() {
    #expect(APIClient.inMemory(cards: []).isConfigured())
  }

  @Test func aRequestWithoutAURLThrowsBeforeAnyNetworkCall() async {
    let client = APIClient.live(baseURL: { nil }, token: { "s3" })
    await #expect(throws: URLError(.unsupportedURL)) { try await client.stats() }
  }

  @Test func onlyA401OrA403MeansTheTokenWasRejected() {
    #expect(APIError(statusCode: 401, message: "").isUnauthorized)
    #expect(APIError(statusCode: 403, message: "").isUnauthorized)
    #expect(!APIError(statusCode: 404, message: "").isUnauthorized)
    #expect(!APIError(statusCode: 500, message: "").isUnauthorized)
  }
}
