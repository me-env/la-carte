import Dependencies
import DependenciesMacros
import Foundation

/// Everything the app can ask the la-carte API. Mirrors `api/src/la_carte_api/rest.py`.
@DependencyClient
public struct APIClient: Sendable {
  public var dueCards: @Sendable (_ limit: Int) async throws -> [Card]
  public var updateCard: @Sendable (_ id: Card.ID, _ front: String, _ back: String) async throws -> Card
  public var review: @Sendable (_ id: Card.ID, _ rating: Rating) async throws -> Card
  /// Holds the card out of study until an agent closes the report (spec 015). A nil `comment` sends no key.
  public var reportCard: @Sendable (_ id: Card.ID, _ reason: ReportReason, _ comment: String?) async throws -> Void
  public var stats: @Sendable () async throws -> DeckStats
  public var notes: @Sendable (_ query: String?) async throws -> [Note]
  public var addNote: @Sendable (_ draft: NoteDraft) async throws -> Note
  /// Sends every field of the draft's type (absent ones as `""`, which clears them) and the full set of directions.
  public var updateNote: @Sendable (_ id: Note.ID, _ draft: NoteDraft) async throws -> Note
  public var deleteNote: @Sendable (_ id: Note.ID) async throws -> Void
  /// `POST /activity` (spec 029): returns on 2xx, throws `APIError` on any other status.
  public var sendActivity: @Sendable (_ events: [ActivityEvent]) async throws -> Void
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
