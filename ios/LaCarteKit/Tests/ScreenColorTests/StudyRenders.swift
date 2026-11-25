import APIClient
import ComposableArchitecture
import DesignSystem
import Foundation
import SwiftUI
import Testing

@testable import StudyFeature

/// The real `StudyView` drawn to PNGs in known states, for design reviews: no simulator UI, no hand-built mocks.
/// Off by default; `scripts/ios-test.sh --render -only-testing:ScreenColorTests/StudyRenders` turns it on and writes
/// `screen-study-<state>-<theme>-<scheme>.png` (docs/testing.md). To add a state, add a line to `catalogue`.
///
/// Uses only `cards`, `phase`, `isRevealed`, `swipeEase`, `editing`, `draft`, `ladder` and `notice`, so feature branches
/// merge cheaply.
/// Not here: the next card's fade-in (spec 017) is view animation, not store state, so it has no state to render.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LA_CARTE_RENDER_DIR"] != nil), .serialized)
struct StudyRenders {
  /// Light, dark, forest; System (on a dark device) only for the empty and done screens.
  static let looks = [
    Look(theme: .light, scheme: .light, palette: .light),
    Look(theme: .dark, scheme: .dark, palette: .dark),
    Look(theme: .forest, scheme: .dark, palette: .forest),
  ]
  static let system = Look(theme: .system, scheme: .dark, palette: .dark)

  /// One state per render: its file name part, and the store state.
  static var catalogue: [(name: String, state: StudyFeature.State, system: Bool)] {
    var shots: [(String, StudyFeature.State, Bool)] = []
    for (tier, card) in Fixture.fronts {
      shots.append(("front-\(tier)", studying(card), false))
    }
    shots.append(("revealed-short", studying(Fixture.short, revealed: true), false))
    shots.append(("revealed-long", studying(Fixture.longAnswer, revealed: true), false))
    // A held rating drag (spec 019): the dial is centred, since the touch point is view state. The store holds the
    // projected value only, so an "up" drag renders as the "right" one of the same length (UI tests hold it with
    // `-studySwipePreviewUp`). Forgot, Hard, dead zone left, touch-down, dead zone right, Got it, Easy.
    for ease in [0.0, 0.25, 0.42, 0.5, 0.58, 0.76, 1.0] {
      var state = studying(Fixture.short, revealed: true)
      state.swipeEase = ease
      shots.append(("drag-\(String(format: "%03d", Int((ease * 100).rounded())))", state, false))
    }
    var editing = studying(Fixture.medium, revealed: true)
    editing.editing = .back
    editing.draft = Fixture.medium.back
    shots.append(("editing-back", editing, false))
    var empty = StudyFeature.State()
    empty.phase = .empty
    shots.append(("empty", empty, true))
    var done = StudyFeature.State()
    done.phase = .caughtUp(nextDue: .now + 3.5 * 3600)  // "Next card in 3 hours"
    shots.append(("done", done, true))
    // Spec 021's milestone ladder: the mockup's five counters and the three step notices.
    for (name, stats) in Ladders.states {
      var state = studying(Fixture.short)
      state.ladder = Ladder(stats: stats)
      shots.append(("ladder-\(name)", state, false))
    }
    for (name, step) in [("atrisk", "At risk"), ("reviews", "Reviews"), ("new", "15 new")] {
      var state = studying(Fixture.short)
      state.notice = .stepDone(step)
      shots.append(("notice-\(name)", state, false))
    }
    return shots
  }

  static func studying(_ card: Card, revealed: Bool = false) -> StudyFeature.State {
    var state = StudyFeature.State()
    state.cards = IdentifiedArray(uniqueElements: [card] + [Card].fixtures)
    state.phase = .studying
    state.isRevealed = revealed
    return state
  }

  /// Drawn by `Screen` (`layer.render`, Liquid Glass hidden). `drawHierarchy(in:afterScreenUpdates: true)` would keep
  /// the glass, but in this test process it returns a blank white image (tried 2026-11-22, with and without a scene).
  @Test func study() throws {
    let dir = try #require(ProcessInfo.processInfo.environment["LA_CARTE_RENDER_DIR"])
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var count = 0
    for (name, state, withSystem) in Self.catalogue {
      for look in Self.looks + (withSystem ? [Self.system] : []) {
        // Writes screen-study-<name>-<theme>-<scheme>.png.
        // Reduce Motion: the logo as it lands (this render drops 3D transforms, so it can't draw the tilt).
        let view = StudyView(store: Store(initialState: state) { EmptyReducer() })
          .environment(\._accessibilityReduceMotion, true)
        _ = try Screen(view, look, name: "study-\(name)")
        count += 1
      }
    }
    print("StudyRenders: \(count) PNGs in \(dir)")
    print("StudyRenders: Liquid Glass hidden in these renders; judge glass on UI-test screenshots")
  }

  /// Spec 021's popover rows, on a surface stand-in for the system glass: `screen-study-milestones-<state>-…png`.
  @Test func milestones() throws {
    for (name, stats) in Ladders.states {
      for look in Self.looks {
        let list = MilestonesList(rows: Ladder(stats: stats).rows)
          .frame(width: 220)
          .background(Theme.surface, in: .rect(cornerRadius: 20))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Theme.background)
        _ = try Screen(list, look, pointHeight: 300, name: "study-milestones-\(name)")
      }
    }
  }

  /// Spec 017's candidate layouts side by side, revealed, light: `screen-study-layout-<A-D>-q<question>-a<lines>.png`
  /// (question: its line count, or `w<percent>` for a single line filling that share of the column). Only cards
  /// where the layouts differ: a side of 3+ lines, or a 2+ line answer under a question D lays it inside.
  @Test func layouts() throws {
    let defaultLayout = StudyView.textLayout
    defer { StudyView.textLayout = defaultLayout }
    let questions = CardLines.questions.map { ("\($0.0)", $0.1, $0.0) } + CardLines.singleLines.map { ("w\($0.0)", $0.1, 1) }
    for (layout, letter) in zip(StudyView.TextLayout.allCases, ["A", "B", "C", "D"]) {
      StudyView.textLayout = layout
      for (q, question, lines) in questions {
        for (a, answer) in CardLines.answers where lines >= 3 || a >= 3 || (a >= 2 && CardLines.wide.contains(question)) {
          let state = Self.studying(CardLines.card(question, answer), revealed: true)
          _ = try Screen(StudyView(store: Store(initialState: state) { EmptyReducer() }), Self.looks[0],
                         name: "study-layout-\(letter)-q\(q)-a\(a)")
        }
      }
    }
  }

  /// Layout D under a 2-line question that fills ~68 % of the column, revealed, light: a short answer, centred, and a
  /// long one, leading; both in the full column (`screen-study-d-wrapped-<short|long>.png`, amended 2026-11-22).
  @Test func layoutDNarrowWrappingQuestion() throws {
    let dir = try #require(ProcessInfo.processInfo.environment["LA_CARTE_RENDER_DIR"])
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, answer) in [("short", "Wolfgang Amadeus Mozart"), ("long", CardLines.answers[2].1)] {
      let state = Self.studying(CardLines.card(CardLines.narrowWrapping, answer), revealed: true)
      _ = try Screen(StudyView(store: Store(initialState: state) { EmptyReducer() }), Self.looks[0],
                     name: "study-d-wrapped-\(name)")
    }
  }

  /// Person cards (spec 014d), light and dark: every direction with a short, a long and no description, before and
  /// after reveal, with and without a photo (`screen-study-person-<photo|name|desc|nophoto-name|nophoto-desc>-<short|long|none>-<q|rev>-<theme>-<scheme>.png`). The photo
  /// URL never loads, so the placeholder stands in for it.
  @Test func personCards() throws {
    let dir = try #require(ProcessInfo.processInfo.environment["LA_CARTE_RENDER_DIR"])
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let date = Date(timeIntervalSince1970: 1_767_225_600)
    let descriptions = [
      ("short", "runs the bakery"),
      ("long", "runs the bakery on the corner of Elm Street and sings in the choir every Sunday morning with her two sisters"),
      ("none", ""),
    ]
    let directions = [
      ("photo", ["photo"], ["name", "description"]),
      ("name", ["name"], ["photo", "description"]),
      ("desc", ["description"], ["photo", "name"]),
      ("nophoto-name", ["name"], ["description"]),
      ("nophoto-desc", ["description"], ["name"]),
    ]
    for (length, description) in descriptions {
      for (direction, prompt, answer) in directions where !(description.isEmpty && direction.hasSuffix("desc")) {
        let photo = direction.hasPrefix("nophoto") ? "" : "https://invalid.example/p.jpg"
        let fields = ["photo": photo, "name": "Ada Example", "description": description]
        let card = Card(id: UUID(), type: .person, prompt: prompt, answer: answer, fields: fields,
                        front: "", back: "", due: date, createdAt: date, updatedAt: date)
        for revealed in [false, true] {
          for look in Self.looks.prefix(2) {
            _ = try Screen(StudyView(store: Store(initialState: Self.studying(card, revealed: revealed)) { EmptyReducer() }),
                           look, name: "study-person-\(direction)-\(length)-\(revealed ? "rev" : "q")")
          }
        }
      }
    }
  }
}

/// Spec 021's mockup states (`docs/design/renders/021/milestone-ladder.png`).
private enum Ladders {
  static func stats(atRisk: (Int, Int), reviews: (Int, Int), newToday: Int, dueNew: Int) -> DeckStats {
    DeckStats(
      total: 120, due: 64, new: 40, reviewedToday: 0, nextDue: nil, newToday: newToday, dueNew: dueNew,
      atRiskTotal: atRisk.1, atRiskDone: atRisk.0, reviewsTotal: reviews.1, reviewsDone: reviews.0
    )
  }

  static let states = [
    ("1-backlog", stats(atRisk: (6, 14), reviews: (6, 52), newToday: 0, dueNew: 40)),
    ("2-reviews", stats(atRisk: (14, 14), reviews: (30, 52), newToday: 0, dueNew: 40)),
    ("3-first-new", stats(atRisk: (14, 14), reviews: (52, 52), newToday: 9, dueNew: 40)),
    ("4-many-new", stats(atRisk: (14, 14), reviews: (52, 52), newToday: 49, dueNew: 30)),
    ("5-normal", stats(atRisk: (0, 0), reviews: (12, 20), newToday: 0, dueNew: 0)),
  ]
}

/// Questions and answers of known rendered line counts on an iPhone 17 Pro at the default text size (spec 017).
enum CardLines {
  static let questions = [
    (1, "la mer"),
    (2, "What is the largest planet in the Solar System?"),
    (2, "Who composed The Magic Flute?"),
    (3, "Which treaty, signed in 1648 in Osnabrück and Münster, ended the Thirty Years' War in Europe?"),
    (5, "Which treaty, signed in 1648 in the cities of Osnabrück and Münster, ended the Thirty Years' War and is "
      + "often cited as the origin of the modern state system?"),
  ]
  /// Single-line questions and the share of the column they fill (percent): layout D's 85 % threshold edges.
  static let singleLines = [
    (74, "the Mediterranean"),
    (89, "Who discovered penicillin?"),
    (92, "the Mediterranean Sea"),
    (98, "What does ephemeral mean?"),
  ]
  /// Wraps, but its widest drawn line fills only ~68 % of the column.
  static let narrowWrapping = "Who composed The Magic Flute?"
  /// The questions layout D lays a leading answer inside: their widest drawn line fills at least 85 % of the column
  /// (the other 2+ line questions: 91-93 %).
  static let wide = questions.filter { $0.0 >= 2 && $0.1 != narrowWrapping }.map(\.1)
    + singleLines.filter { $0.0 >= 85 }.map(\.1)
  static let answers = [
    (1, "the sea"),
    (2, "Jupiter, a gas giant mostly made of hydrogen and helium"),
    (4, "The Peace of Westphalia: two treaties signed in Osnabrück and Münster that ended the war in the Holy Roman "
      + "Empire and the Eighty Years' War between Spain and the Dutch Republic."),
  ]

  static func card(_ front: String, _ back: String) -> Card {
    let date = Date(timeIntervalSince1970: 1_767_225_600)
    return Card(id: UUID(), front: front, back: back, due: date, createdAt: date, updatedAt: date)
  }
}

/// Demo-safe English cards, one per length tier. Spec 017 measures the shown text after trimming: short ≤ 24
/// characters, medium 25–60, long > 60 (or a line break); overflowing is long enough (> 500) that the card scrolls.
private enum Fixture {
  static let date = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01

  static func card(_ n: Int, _ front: String, _ back: String) -> Card {
    Card(id: UUID(uuidString: "00000000-0000-0000-0000-0000000001\(n)0")!, front: front, back: back,
         due: date, createdAt: date, updatedAt: date)
  }

  static let short = card(1, "la mer", "the sea")
  static let medium = card(2, "What is the largest planet in the Solar System?", "Jupiter")
  static let long = card(3,
    "Which treaty, signed in 1648, ended the Thirty Years' War and is often cited as the origin of the modern state system?",
    "The Peace of Westphalia")
  static let overflowing = card(4, """
    Read the passage and name the process it describes. Green plants, algae and some bacteria take in light, \
    usually from the sun, and use its energy to turn water and carbon dioxide from the air into sugars. The \
    sugars feed the plant and are stored as starch for later. Oxygen is released as a by-product, through small \
    pores in the leaves. The reaction happens mostly in the leaves, inside small green bodies in each cell that \
    hold a pigment which absorbs red and blue light and reflects green, which is why most plants look green. \
    Almost all life on land depends on it, directly or through the food chain. What is it called?
    """,
    "Photosynthesis: light energy turns water and carbon dioxide into sugar and oxygen, in the chloroplasts of plant cells.")
  static let longAnswer = card(5, "mitochondria",
    "The organelle that produces most of the cell's energy (ATP) through cellular respiration, often called the powerhouse of the cell.")

  static let fronts = [("short", short), ("medium", medium), ("long", long), ("overflowing", overflowing)]
}
