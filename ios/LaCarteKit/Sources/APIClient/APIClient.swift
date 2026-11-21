import Dependencies
import DependenciesMacros
import Foundation

/// Everything the app can ask the la-carte API. Mirrors `api/src/la_carte_api/rest.py`.
@DependencyClient
public struct APIClient: Sendable {
  public var cards: @Sendable (_ query: String?) async throws -> [Card]
  public var dueCards: @Sendable (_ limit: Int) async throws -> [Card]
  public var addCard: @Sendable (_ front: String, _ back: String) async throws -> Card
  public var updateCard: @Sendable (_ id: Card.ID, _ front: String, _ back: String) async throws -> Card
  public var deleteCard: @Sendable (_ id: Card.ID) async throws -> Void
  public var review: @Sendable (_ id: Card.ID, _ rating: Rating) async throws -> Card
  public var stats: @Sendable () async throws -> DeckStats
  /// False until a server URL and a token are both set: features show "Connect your deck" instead of loading.
  public var isConfigured: @Sendable () -> Bool = { false }
}

extension APIClient: TestDependencyKey {
  public static let testValue = APIClient()
  public static var previewValue: APIClient { .inMemory(cards: .fixtures) }
}

extension DependencyValues {
  public var apiClient: APIClient {
    get { self[APIClient.self] }
    set { self[APIClient.self] = newValue }
  }
}
