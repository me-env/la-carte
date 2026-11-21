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
        fields: ["name": "Ada Example", "role": "runs the bakery"],
        directions: [Direction(prompt: ["role"], answer: ["name"])]
      )
    )

    let request = try #require(requests.value.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path() == "/notes")
    #expect(
      try body(request) == [
        "type": "person",
        "fields": ["name": "Ada Example", "role": "runs the bakery"],
        "directions": [["prompt": ["role"], "answer": ["name"]]],
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
        "fields": ["photo": "", "name": "Ada Example", "role": "", "context": ""],
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

  private func capturing(response json: String) -> (APIClient, LockIsolated<[URLRequest]>) {
    let requests = LockIsolated<[URLRequest]>([])
    let client = APIClient.live(
      baseURL: { URL(string: "https://deck.example") },
      token: { "token" },
      load: { request in
        requests.withValue { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
      }
    )
    return (client, requests)
  }

  private func body(_ request: URLRequest) throws -> NSDictionary {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
  }

  private let noteJSON = """
    {"id":"0b3c8a52-4f43-4a57-9d55-3b0f4c1d9e21","type":"person","fields":{"name":"Ada Example"},"cards":[],
     "created_at":"2026-11-20T22:14:52Z","updated_at":"2026-11-20T22:14:52Z"}
    """
}
