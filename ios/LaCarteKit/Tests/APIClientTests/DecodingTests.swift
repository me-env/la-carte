import Foundation
import Testing

@testable import APIClient

/// Contract tests: payloads copied from the real API (`api/`). Update both sides together.
struct DecodingTests {
  @Test func decodesCard() throws {
    let json = """
      {"id":"65f15766-7ab3-4c84-bb05-ae180e083bef","front":"bonjour","back":"hello",
       "state":"new","due":"2026-11-20T22:14:52.426509Z","last_review":null,
       "created_at":"2026-11-20T22:14:52.426509Z","updated_at":"2026-11-20T22:14:52Z"}
      """
    let card = try JSONDecoder.api.decode(Card.self, from: Data(json.utf8))
    #expect(card.front == "bonjour")
    #expect(card.state == .new)
    #expect(card.lastReview == nil)
    #expect(card.updatedAt == Date(timeIntervalSince1970: 1_795_212_892))
  }

  @Test func decodesStatsWithNextDue() throws {
    let json = #"{"total":2,"due":0,"new":0,"reviewed_today":2,"next_due":"2026-11-20T23:24:08.477041Z","streak":12}"#
    let stats = try JSONDecoder.api.decode(DeckStats.self, from: Data(json.utf8))
    #expect(stats.total == 2)
    #expect(stats.reviewedToday == 2)
    #expect(stats.streak == 12)
    let nextDue = try #require(stats.nextDue)
    #expect(abs(nextDue.timeIntervalSince1970 - 1_795_217_048.477) < 0.001)
  }

  @Test func decodesStatsWithoutNextDue() throws {
    let json = #"{"total":0,"due":0,"new":0,"reviewed_today":0,"next_due":null,"streak":0}"#
    let stats = try JSONDecoder.api.decode(DeckStats.self, from: Data(json.utf8))
    #expect(stats == DeckStats(total: 0, due: 0, new: 0, reviewedToday: 0, nextDue: nil, streak: 0))
  }
}
