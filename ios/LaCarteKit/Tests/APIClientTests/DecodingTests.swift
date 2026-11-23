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
    #expect(card.noteId == card.id)
    #expect(card.type == .basic)
    #expect(card.prompt == ["front"])
    #expect(card.answer == ["back"])
    #expect(card.fields == ["front": "bonjour", "back": "hello"])
  }

  @Test func decodesNoteCard() throws {
    let json = """
      {"id":"65f15766-7ab3-4c84-bb05-ae180e083bef","note_id":"0b3c8a52-4f43-4a57-9d55-3b0f4c1d9e21",
       "type":"person","prompt":["photo"],"answer":["name","description"],
       "fields":{"photo":"https://example.org/p/42.jpg","name":"Ada Example","description":"runs the bakery"},
       "front":"https://example.org/p/42.jpg","back":"Ada Example\\nruns the bakery",
       "state":"new","due":"2026-11-20T22:14:52.426509Z","last_review":null,
       "created_at":"2026-11-20T22:14:52.426509Z","updated_at":"2026-11-20T22:14:52Z"}
      """
    let card = try JSONDecoder.api.decode(Card.self, from: Data(json.utf8))
    #expect(card.noteId == UUID(uuidString: "0b3c8a52-4f43-4a57-9d55-3b0f4c1d9e21"))
    #expect(card.type == .person)
    #expect(card.prompt == ["photo"])
    #expect(card.answer == ["name", "description"])
    #expect(card.fields["description"] == "runs the bakery")
    #expect(card.back == "Ada Example\nruns the bakery")
  }

  @Test func decodesNote() throws {
    let json = """
      {"id":"0b3c8a52-4f43-4a57-9d55-3b0f4c1d9e21","type":"person",
       "fields":{"photo":"https://example.org/p/42.jpg","name":"Ada Example","description":"runs the bakery"},
       "cards":[{"id":"65f15766-7ab3-4c84-bb05-ae180e083bef","prompt":["photo"],"answer":["name"],
                 "state":"new","due":"2026-11-20T22:14:52.426509Z","last_review":null}],
       "created_at":"2026-11-20T22:14:52.426509Z","updated_at":"2026-11-20T22:14:52Z"}
      """
    let note = try JSONDecoder.api.decode(Note.self, from: Data(json.utf8))
    #expect(note.type == .person)
    #expect(note.fields["name"] == "Ada Example")
    #expect(note.cards.count == 1)
    #expect(note.cards[0].direction == Direction(prompt: ["photo"], answer: ["name"]))
    #expect(note.cards[0].state == .new)
    #expect(note.cards[0].lastReview == nil)
    #expect(note.updatedAt == Date(timeIntervalSince1970: 1_795_212_892))
  }

  /// A real `/stats?tz=Europe/Paris` reply (spec 024 step 1).
  static let statsPayload = """
    {"total":120,"due":64,"new":45,"reviewed_today":30,"next_due":"2026-11-20T23:24:08.477041Z",
     "new_today":19,"milestone":15,"streak":25,"streak_start":"2026-10-29",
     "history_start":"2026-10-26","history":"smmsssssssssfssssssssssfssss","due_new":45}
    """

  @Test func decodesStats() throws {
    let stats = try JSONDecoder.api.decode(DeckStats.self, from: Data(Self.statsPayload.utf8))
    #expect(stats.total == 120)
    #expect(stats.reviewedToday == 30)
    #expect(stats.newToday == 19)
    #expect(stats.milestone == 15)
    #expect(stats.streak == 25)
    #expect(stats.dueNew == 45)
    #expect(stats.history.count == 28)
    let nextDue = try #require(stats.nextDue)
    #expect(abs(nextDue.timeIntervalSince1970 - 1_795_217_048.477) < 0.001)
    let calendar = DeckStats.calendar
    #expect(stats.historyStart == calendar.date(from: DateComponents(year: 2026, month: 10, day: 26)))
    #expect(stats.streakStart == calendar.date(from: DateComponents(year: 2026, month: 10, day: 29)))
  }

  /// No reviews yet: no streak start. `new_today` / `milestone` absent read as 0 / 15 (the hand-off's defaults).
  @Test func decodesStatsWithoutStreakOrBatch() throws {
    let json = """
      {"total":0,"due":0,"new":0,"reviewed_today":0,"next_due":null,"streak":0,"streak_start":null,
       "history_start":"2026-11-22","history":"p","due_new":0}
      """
    let stats = try JSONDecoder.api.decode(DeckStats.self, from: Data(json.utf8))
    let today = try #require(DeckStats.calendar.date(from: DateComponents(year: 2026, month: 11, day: 22)))
    #expect(stats == DeckStats(total: 0, due: 0, new: 0, reviewedToday: 0, nextDue: nil, history: "p", historyStart: today))
  }

  @Test func rejectsAMalformedDay() {
    let json = Self.statsPayload.replacingOccurrences(of: "2026-10-26", with: "26/10/2026")
    #expect(throws: DecodingError.self) { try JSONDecoder.api.decode(DeckStats.self, from: Data(json.utf8)) }
  }

  /// The widget caches the last stats with a plain encoder (spec 007): it must read back the same days.
  @Test func statsRoundTripThroughTheWidgetCache() throws {
    let stats = try JSONDecoder.api.decode(DeckStats.self, from: Data(Self.statsPayload.utf8))
    let cached = try JSONDecoder().decode(DeckStats.self, from: JSONEncoder().encode(stats))
    #expect(cached == stats)
  }

  /// Spec 024 #9: Study's count, from `/stats` alone.
  @Test func toReviewCountsNewCardsUpToTheEndOfTodaysBatch() {
    var stats = DeckStats(total: 120, due: 64, new: 45, reviewedToday: 30, nextDue: nil, newToday: 19, dueNew: 45)
    #expect(stats.toReview == 19 + 11)
    stats.dueNew = 0
    #expect(stats.toReview == 64)
    stats.dueNew = 5
    #expect(stats.toReview == 59 + 5)
  }

  @Test func reportReasonsEncodeAsTheAPISpellsThem() throws {
    let data = try JSONEncoder().encode(ReportReason.allCases)
    #expect(String(decoding: data, as: UTF8.self) == #"["wrong","drop","doubt","rephrase","other","broken_photo"]"#)
  }
}
