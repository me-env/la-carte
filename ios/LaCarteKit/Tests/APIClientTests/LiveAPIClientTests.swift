import Dependencies
import Foundation
import Testing

@testable import APIClient

/// Request shapes the live client sends, checked against spec 014a's contract without a server.
struct LiveAPIClientTests {
  let noteID = UUID(uuidString: "0b3c8a52-4f43-4a57-9d55-3b0f4c1d9e21")!

  @Test func notesRequestsUpTo500MatchingTheQuery() async throws {
    let (client, requests) = capturing(response: "[]")
    _ = try await client.notes("ada")

    let request = try #require(requests.value.first)
    let components = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    #expect(request.httpMethod == "GET")
    #expect(components.path == "/notes")
    #expect(Set(components.queryItems ?? []) == [.init(name: "limit", value: "500"), .init(name: "query", value: "ada")])
  }

  @Test func addNoteSendsTypeFieldsAndDirections() async throws {
    let (client, requests) = capturing(response: noteJSON)
    _ = try await client.addNote(
      NoteDraft(
        type: .person,
        fields: ["name": "Ada Example", "description": "runs the bakery"],
        directions: [Direction(prompt: ["description"], answer: ["name"])]
      )
    )

    let request = try #require(requests.value.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path() == "/notes")
    #expect(
      try body(request) == [
        "type": "person",
        "fields": ["name": "Ada Example", "description": "runs the bakery"],
        "directions": [["prompt": ["description"], "answer": ["name"]]],
      ]
    )
  }

  @Test func updateNoteSendsEveryFieldOfTheTypeAndNoType() async throws {
    let (client, requests) = capturing(response: noteJSON)
    _ = try await client.updateNote(
      noteID,
      NoteDraft(
        type: .person,
        fields: ["name": "Ada Example"],
        directions: [Direction(prompt: ["photo"], answer: ["name"])]
      )
    )

    let request = try #require(requests.value.first)
    #expect(request.httpMethod == "PATCH")
    #expect(request.url?.path() == "/notes/\(noteID)")
    #expect(
      try body(request) == [
        "fields": ["photo": "", "name": "Ada Example", "description": ""],
        "directions": [["prompt": ["photo"], "answer": ["name"]]],
      ]
    )
  }

  @Test func deleteNoteDeletesTheNote() async throws {
    let (client, requests) = capturing(response: "")
    try await client.deleteNote(noteID)

    let request = try #require(requests.value.first)
    #expect(request.httpMethod == "DELETE")
    #expect(request.url?.path() == "/notes/\(noteID)")
  }

  @Test func reportCardSendsTheReasonWithoutACommentKey() async throws {
    let (client, requests) = capturing(response: reportJSON, statusCode: 201)
    try await client.reportCard(noteID, .wrong, nil)

    let request = try #require(requests.value.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path() == "/cards/\(noteID)/report")
    #expect(try body(request) == ["reason": "wrong"])
  }

  @Test func reportCardSendsTheCommentWhenThereIsOne() async throws {
    let (client, requests) = capturing(response: reportJSON, statusCode: 201)
    try await client.reportCard(noteID, .other, "typo in the answer")
    try await client.reportCard(noteID, .brokenPhoto, "https://example.org/p/42.jpg")

    #expect(try body(requests.value[0]) == ["reason": "other", "comment": "typo in the answer"])
    #expect(try body(requests.value[1]) == ["reason": "broken_photo", "comment": "https://example.org/p/42.jpg"])
  }

  private func capturing(response json: String, statusCode: Int = 200) -> (APIClient, LockIsolated<[URLRequest]>) {
    let requests = LockIsolated<[URLRequest]>([])
    let client = APIClient.live(
      baseURL: { URL(string: "https://deck.example") },
      token: { "token" },
      load: { request in
        requests.withValue { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
      }
    )
    return (client, requests)
  }

  private func body(_ request: URLRequest) throws -> NSDictionary {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
  }

  /// `POST /cards/{id}/report` → 201, as the API returns it (spec 015a); the client ignores the body.
  private let reportJSON = """
    {"id":"9a1f0c3e-2b7d-4e55-8f10-6c2d3e4f5a61","card_id":"0b3c8a52-4f43-4a57-9d55-3b0f4c1d9e21",
     "note_id":"0b3c8a52-4f43-4a57-9d55-3b0f4c1d9e21","reason":"wrong","comment":null,"status":"open",
     "resolution":null,"created_at":"2026-11-21T09:00:00Z","updated_at":"2026-11-21T09:00:00Z",
     "resolved_at":null,"card":null}
    """

  private let noteJSON = """
    {"id":"0b3c8a52-4f43-4a57-9d55-3b0f4c1d9e21","type":"person","fields":{"name":"Ada Example"},"cards":[],
     "created_at":"2026-11-20T22:14:52Z","updated_at":"2026-11-20T22:14:52Z"}
    """
}
