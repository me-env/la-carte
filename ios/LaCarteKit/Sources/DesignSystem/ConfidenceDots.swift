import SwiftUI

/// A ring of ink dots whose order shows how sure the user is (spec 011): `order` 1 is a perfectly regular ring,
/// 0 is scattered noise. No color, no text: the shape alone carries the value. The ring follows `order` with no
/// animation of its own, so it moves only when the caller's value does.
public struct ConfidenceDots: View {
  let order: Double
  let radius: CGFloat

  public init(order: Double, radius: CGFloat) {
    self.order = order
    self.radius = radius
  }

  public var body: some View {
    let side = 2 * radius * (1 + DotRing.radialJitter) + DotRing.dotDiameter * (1 + DotRing.sizeJitter)
    ZStack {
      ForEach(Array(DotRing(order: order).dots.enumerated()), id: \.offset) { _, dot in
        Circle()
          .fill(Theme.ink)
          .frame(width: DotRing.dotDiameter * dot.scale, height: DotRing.dotDiameter * dot.scale)
          .offset(x: dot.center.x * radius, y: dot.center.y * radius)
      }
    }
    .frame(width: side, height: side)
  }
}

/// The dot layout as a pure, seeded function of `order` (tested in `ConfidenceDotsTests`). Every geometry constant
/// lives here so design-lead can tune them in one place (pending design-lead; meant to be shared with the logo's dots).
struct DotRing: Equatable {
  static let count = 16
  /// Diameter of a dot on the regular ring, in points.
  static let dotDiameter: CGFloat = 6
  /// At full noise, a dot's diameter varies by up to ± this fraction (6 pt ± 33% stays at least 4 pt).
  static let sizeJitter: CGFloat = 0.33
  /// At full noise, a dot moves off the circle by up to ± this fraction of the radius.
  static let radialJitter: CGFloat = 0.45
  /// At full noise, a dot slides along the circle by up to ± this fraction of the gap between two dots.
  static let tangentialJitter: CGFloat = 0.5
  static let seed: UInt64 = 0x1A_CA27E

  /// Each dot's fixed random offsets in -1...1 (radial, tangential, size), drawn once from `seed`.
  private static let offsets: [(radial: CGFloat, tangential: CGFloat, size: CGFloat)] = {
    var generator = SplitMix64(state: seed)
    return (0..<count).map { _ in
      (
        CGFloat.random(in: -1...1, using: &generator),
        CGFloat.random(in: -1...1, using: &generator),
        CGFloat.random(in: -1...1, using: &generator)
      )
    }
  }()

  struct Dot: Equatable {
    /// Relative to the ring's center, in units of the radius.
    var center: CGPoint
    /// Multiplier of `dotDiameter`.
    var scale: CGFloat
  }

  var dots: [Dot]

  init(order: Double) {
    let noise = 1 - CGFloat(min(max(order, 0), 1))
    let step = 2 * CGFloat.pi / CGFloat(Self.count)
    dots = Self.offsets.enumerated().map { index, offset in
      let angle = CGFloat(index) * step + offset.tangential * Self.tangentialJitter * step * noise
      let distance = 1 + offset.radial * Self.radialJitter * noise
      return Dot(
        center: CGPoint(x: distance * cos(angle), y: distance * sin(angle)),
        scale: 1 + offset.size * Self.sizeJitter * noise
      )
    }
  }
}

/// A tiny seeded generator, so the noise is the same on every run and every device.
private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

#Preview("Confidence dots") {
  HStack(spacing: Theme.Spacing.m) {
    ForEach([0, 0.25, 0.5, 0.75, 1], id: \.self) { order in
      ConfidenceDots(order: order, radius: 28)
    }
  }
  .padding()
  .background(Theme.background)
}
