import SwiftUI

/// The dial around the finger during a rating drag (spec 019): a ring of 24 dots that fills clockwise toward
/// "Got it" / "Easy" (discs) or counter-clockwise toward "Hard" / "Forgot" (rings). Half the ring is the first
/// grade, the full ring the second; the armed dots pulse once when a grade is reached. Ink tokens only, so it
/// reads in grayscale. The fill follows `value` with no animation of its own.
public struct RatingDial: View {
  let value: Double
  let radius: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulses = 0

  /// `value` is the ease 0...1 (0.5 = touch-down); `radius` is the distance from the center to the dots.
  public init(value: Double, radius: CGFloat) {
    self.value = value
    self.radius = radius
  }

  public var body: some View {
    let layout = RatingDialLayout(value: value)
    KeyframeAnimator(initialValue: 1.0, trigger: pulses) { pulse in
      ZStack {
        ForEach(Array(layout.dots.enumerated()), id: \.offset) { _, dot in
          let angle = dot.angle * .pi / 180
          dotShape(dot)
            .frame(width: dot.diameter, height: dot.diameter)
            .opacity(dot.opacity)
            .scaleEffect(dot.kind == .armed ? pulse : 1)
            .offset(x: radius * sin(angle), y: -radius * cos(angle))
        }
      }
    } keyframes: { _ in
      KeyframeTrack {
        LinearKeyframe(1.3, duration: 0.1, timingCurve: .easeOut)
        LinearKeyframe(1, duration: 0.1, timingCurve: .easeIn)
      }
    }
    .frame(width: 2 * radius + 8, height: 2 * radius + 8)
    .onChange(of: layout.stage) { old, new in
      if new > old, !reduceMotion { pulses += 1 }
    }
  }

  @ViewBuilder private func dotShape(_ dot: RatingDialLayout.Dot) -> some View {
    let color = dot.kind == .armed ? Theme.ink : Theme.secondaryInk
    if dot.isRing {
      Circle().strokeBorder(color, lineWidth: 1.5)
    } else {
      Circle().fill(color)
    }
  }
}

/// The dial's dots as a pure function of the ease (tested in `RatingDialTests`), so the geometry and the grade
/// stages can be checked without drawing.
struct RatingDialLayout: Equatable {
  static let count = 24

  /// How far the drag has gone: no grade, the first grade (Hard / Got it), the second (Forgot / Easy).
  enum Stage: Int, Comparable {
    case none, first, second

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  struct Dot: Equatable {
    enum Kind: Equatable { case track, pending, armed }

    /// Degrees clockwise from 12 o'clock, in 0..<360.
    var angle: Double
    /// How much of the dot the drag has reached, 0...1.
    var fill: Double
    var kind: Kind
    /// The negative side's reached dots are rings, so Forgot never looks like Easy, nor Hard like Got it.
    var isRing: Bool

    var diameter: CGFloat {
      switch kind {
      case .track: 4
      case .pending: 4 + 2 * fill
      case .armed: 6
      }
    }

    var opacity: Double {
      switch kind {
      case .track: 0.45
      case .pending: 0.4 + 0.6 * fill
      case .armed: 1
      }
    }
  }

  var stage: Stage
  var dots: [Dot]

  init(value: Double) {
    let isPositive = value >= 0.5
    let m = min(abs(value - 0.5) * 2, 1)
    // 011's bin edges (`StudyFeature.rating(forEase:)`), written on the value so the two always agree.
    let stage: Stage =
      value <= 0.125 || value >= 0.875 ? .second
      : value <= 0.35 || value >= 0.65 ? .first
      : .none
    self.stage = stage
    // Half the ring across the dead zone (m < 0.3), the other half up to the second grade (m = 0.75).
    let filled = m < 0.3 ? 12 * m / 0.3 : min(12 + 12 * (m - 0.3) / 0.45, 24)
    dots = (0..<Self.count).map { k in
      let fill = min(max(filled - Double(k), 0), 1)
      let isArmed = stage == .second || (stage == .first && k < 12)
      let kind: Dot.Kind = isArmed ? .armed : fill > 0 ? .pending : .track
      let offset = (Double(k) + 0.5) * 15
      return Dot(
        angle: isPositive ? offset : 360 - offset,
        fill: fill,
        kind: kind,
        isRing: !isPositive && kind != .track
      )
    }
  }
}

#Preview("Rating dial") {
  HStack(spacing: Theme.Spacing.s) {
    ForEach([0, 0.3, 0.42, 0.5, 0.58, 0.7, 1], id: \.self) { value in
      RatingDial(value: value, radius: 20)
    }
  }
  .padding()
  .background(Theme.background)
}
