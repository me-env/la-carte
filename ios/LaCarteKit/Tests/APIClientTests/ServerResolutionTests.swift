import Foundation
import Testing

@testable import APIClient

/// Spec 003 #6: launch env > value stored by Settings > default, resolved on every request.
struct ServerResolutionTests {
  let fallback = URL(string: "http://127.0.0.1:8000")!

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

  @Test func missingOrInvalidStoredURLFallsBackToTheDefault() {
    #expect(APIClient.resolvedBaseURL(environment: [:], stored: nil) == fallback)
    #expect(APIClient.resolvedBaseURL(environment: [:], stored: "") == fallback)
    #expect(APIClient.resolvedBaseURL(environment: [:], stored: "cards.example.com") == fallback)
    #expect(APIClient.resolvedBaseURL(environment: [:], stored: "ftp://cards.example.com") == fallback)
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
}
