import APIClient
import ComposableArchitecture
import Foundation
import SwiftUI
import Testing

@testable import StudyFeature

/// The real `StudyView` drawn to PNGs in known states, for design reviews: no simulator UI, no hand-built mocks.
/// Off by default; `scripts/ios-test.sh --render -only-testing:ScreenColorTests/StudyRenders` turns it on and writes
/// `screen-study-<state>-<theme>-<scheme>.png` (docs/testing.md). To add a state, add a line to `catalogue`.
///
/// Uses only `cards`, `phase`, `isRevealed`, `swipeEase`, `editing` and `draft`, so feature branches merge cheaply.
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
        _ = try Screen(StudyView(store: Store(initialState: state) { EmptyReducer() }), look, name: "study-\(name)")
        count += 1
      }
    }
    print("StudyRenders: \(count) PNGs in \(dir)")
    print("StudyRenders: Liquid Glass hidden in these renders; judge glass on UI-test screenshots")
  }

  /// Spec 017's candidate layouts side by side, revealed, light: `screen-study-layout-<A|B|C>-q<lines>-a<lines>.png`.
  /// Only cards with a side of 3+ lines: with both sides at 1-2 lines (centred), A, B and C are identical.
  @Test func layouts() throws {
    defer { StudyView.textLayout = .column }
    for (layout, letter) in zip(StudyView.TextLayout.allCases, ["A", "B", "C"]) {
      StudyView.textLayout = layout
      for (q, question) in CardLines.questions {
        for (a, answer) in CardLines.answers where q >= 3 || a >= 3 {
          let state = Self.studying(CardLines.card(question, answer), revealed: true)
          _ = try Screen(StudyView(store: Store(initialState: state) { EmptyReducer() }), Self.looks[0],
                         name: "study-layout-\(letter)-q\(q)-a\(a)")
        }
      }
    }
  }
}

/// Questions and answers of known rendered line counts on an iPhone 17 Pro at the default text size (spec 017).
enum CardLines {
  static let questions = [
    (1, "la mer"),
    (2, "What is the largest planet in the Solar System?"),
    (3, "Which treaty, signed in 1648 in Osnabrück and Münster, ended the Thirty Years' War in Europe?"),
    (5, "Which treaty, signed in 1648 in the cities of Osnabrück and Münster, ended the Thirty Years' War and is "
      + "often cited as the origin of the modern state system?"),
  ]
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
