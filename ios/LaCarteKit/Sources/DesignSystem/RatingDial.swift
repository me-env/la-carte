import SwiftUI

/// The dial around the finger during a rating drag (spec 019): 96 dots whose order is the grade. Toward "Got it" /
/// "Easy" they settle into three even rings on 32 spokes, all one size (fully ordered at Easy); toward "Hard" /
/// "Forgot" they scatter, with varied sizes (fully scattered at Forgot). The scatter is seeded per dot, so it never
/// flickers, and follows `value` continuously with no animation of its own. Once a grade is reached the dots turn
/// ink and pulse once. Ink tokens only, so it reads in grayscale. Drawn in a `Canvas` (96 dots redrawn per frame).
public struct RatingDial: View {
  let value: Double
  let radius: CGFloat
  @Environment(\.self) private var environment
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulses = 0

  /// `value` is the ease 0...1 (0.5 = touch-down); `radius` is the distance from the center to the middle ring.
  public init(value: Double, radius: CGFloat) {
    self.value = value
    self.radius = radius
  }

  public var body: some View {
    let layout = RatingDialLayout(value: value, radius: radius)
    let armed = layout.stage != .none
    let color = (armed ? Theme.ink : Theme.secondaryInk).resolve(in: environment)
    let side = 2 * RatingDialLayout.extent(radius: radius)
    KeyframeAnimator(initialValue: 1.0, trigger: pulses) { pulse in
      Canvas { context, size in
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for dot in layout.dots {
          let d = dot.diameter * (armed ? pulse : 1)
          let rect = CGRect(x: center.x + dot.x - d / 2, y: center.y + dot.y - d / 2, width: d, height: d)
          context.fill(Path(ellipseIn: rect), with: .color(color))
        }
      }
      .opacity(armed ? 1 : 0.6)
    } keyframes: { _ in
      KeyframeTrack {
        LinearKeyframe(1.3, duration: 0.1, timingCurve: .easeOut)
        LinearKeyframe(1, duration: 0.1, timingCurve: .easeIn)
      }
    }
    .frame(width: side, height: side)
    .onChange(of: layout.stage) { old, new in
      if new > old, !reduceMotion { pulses += 1 }
    }
  }
}

/// The dial's dots as a pure function of the ease (tested in `RatingDialTests`), so the order, the sizes and the
/// grade stages can be checked without drawing.
struct RatingDialLayout: Equatable {
  static let rings = 3
  static let spokes = 32
  static var count: Int { rings * spokes }
  /// Ring radii as fractions of `radius`: inner, middle, outer.
  static let ringScale: [CGFloat] = [0.82, 0.91, 1]
  /// The ordered dot, and the scattered sizes' range as multiples of it.
  static let diameter: CGFloat = 4.5
  static let sizeRange: ClosedRange<CGFloat> = 0.6...1.8
  /// How far a scattered dot may drift from its spoke, in spokes, and from its ring, as a fraction of `radius`.
  static let angleDrift = 1.0
  static let radialDrift: CGFloat = 0.15
  /// The smallest space between two dots' edges, in points: `minGap` when ordered, growing with the disorder to
  /// `scatterGap` at Forgot, so dots never touch mid-drag and the full scatter is even, not clumped.
  static let minGap: CGFloat = 1.5
  static let scatterGap: CGFloat = 8
  /// The radius the scatter is spaced at (`StudyView` on iPhone 17 Pro); other radii scale it.
  static let referenceRadius: CGFloat = 108

  /// Disorder of each grade, from Forgot to Easy: 1 is fully scattered, 0 fully ordered. Spaced by how they look:
  /// even a little drift breaks the rings, so the middle stops sit low.
  static let forgot = 1.0, hard = 0.45, rest = 0.3, gotIt = 0.2, easy = 0.0

  /// How far the drag has gone: no grade, the first grade (Hard / Got it), the second (Forgot / Easy).
  enum Stage: Int, Comparable {
    case none, first, second

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  struct Dot: Equatable {
    /// Offset from the dial's center, in points (y down).
    var x: CGFloat
    var y: CGFloat
    var diameter: CGFloat
  }

  var stage: Stage
  /// 0 (ordered) ... 1 (scattered).
  var disorder: Double
  var dots: [Dot]

  /// Half the frame: the outer ring plus the furthest drift and the largest pulsed dot.
  static func extent(radius: CGFloat) -> CGFloat {
    radius * (1 + radialDrift) + diameter * sizeRange.upperBound * 1.3 / 2 + 1
  }

  /// Dot `i` fully ordered: on ring `i / spokes`, spoke `i % spokes`, at `referenceRadius`.
  static func latticePoint(_ i: Int) -> Dot {
    let angle = (Double(i % spokes) + 0.5) * 2 * .pi / Double(spokes)
    let r = referenceRadius * ringScale[i / spokes]
    return Dot(x: r * sin(angle), y: -r * cos(angle), diameter: diameter)
  }

  /// Every dot fully scattered (Forgot), at `referenceRadius`: a seeded drift and size per dot, then spaced to
  /// `scatterGap`. Computed once.
  static let scatter: [Dot] = {
    let step = 2 * Double.pi / Double(spokes)
    let dots = (0..<count).map { i in
      var seed = SplitMix(seed: UInt64(i))
      let (u1, u2, u3) = (seed.unit(), seed.unit(), seed.unit())
      let angle = (Double(i % spokes) + 0.5 + (2 * u1 - 1) * angleDrift) * step
      let r = referenceRadius * (ringScale[i / spokes] + (2 * u2 - 1) * radialDrift)
      // Squared, so most scattered dots are small and a few are large.
      let scale = sizeRange.lowerBound + (sizeRange.upperBound - sizeRange.lowerBound) * u3 * u3
      return Dot(x: r * sin(angle), y: -r * cos(angle), diameter: diameter * scale)
    }
    return spaced(dots, gap: scatterGap, radius: referenceRadius, passes: 80)
  }()

  /// Pushes every pair of dots closer than `gap` (edge to edge) apart, keeping them in the dial's band, until none
  /// is or `passes` run out. Deterministic and continuous in its input, so the dots don't jump between frames.
  static func spaced(_ input: [Dot], gap: CGFloat, radius: CGFloat, passes: Int) -> [Dot] {
    var dots = input
    let band = (radius * (ringScale[0] - radialDrift))...(radius * (1 + radialDrift))
    for _ in 0..<passes {
      var moved = false
      for i in dots.indices {
        for j in dots.indices where j > i {
          let dx = dots[j].x - dots[i].x, dy = dots[j].y - dots[i].y
          let distance = max(hypot(dx, dy), 0.001)
          let push = (dots[i].diameter + dots[j].diameter) / 2 + gap + 0.2 - distance
          guard push > 0.2 else { continue }
          moved = true
          let (px, py) = (dx / distance * push / 2, dy / distance * push / 2)
          dots[i].x -= px; dots[i].y -= py
          dots[j].x += px; dots[j].y += py
        }
      }
      for i in dots.indices {
        let r = hypot(dots[i].x, dots[i].y)
        let clamped = min(max(r, band.lowerBound), band.upperBound)
        dots[i].x *= clamped / r; dots[i].y *= clamped / r
      }
      if !moved { break }
    }
    return dots
  }

  init(value: Double, radius: CGFloat = 108) {
    let m = min(abs(value - 0.5) * 2, 1)
    // 011's bin edges (`StudyFeature.rating(forEase:)`), written on the value so the two always agree.
    stage =
      value <= 0.125 || value >= 0.875 ? .second
      : value <= 0.35 || value >= 0.65 ? .first
      : .none
    // Each stretch (dead zone m < 0.3, first grade up to m = 0.75) holds its own look for 70 % of its travel, then
    // eases into the next one, so a grade reads as itself and not as a blend.
    let (near, far) = value >= 0.5 ? (Self.gotIt, Self.easy) : (Self.hard, Self.forgot)
    func hold(_ from: Double, _ to: Double, _ t: Double) -> Double {
      t < 0.7 ? from : from + (to - from) * min((t - 0.7) / 0.3, 1)
    }
    let disorder = m < 0.3 ? hold(Self.rest, near, m / 0.3) : hold(near, far, (m - 0.3) / 0.45)
    self.disorder = disorder
    let c = CGFloat(disorder), k = radius / Self.referenceRadius
    let blend = (0..<Self.count).map { i in
      let a = Self.latticePoint(i), b = Self.scatter[i]
      return Dot(
        x: k * (a.x + c * (b.x - a.x)),
        y: k * (a.y + c * (b.y - a.y)),
        diameter: a.diameter + c * (b.diameter - a.diameter)
      )
    }
    // The blend of two well-spaced layouts can still bring two dots together mid-way: space it too.
    dots = Self.spaced(blend, gap: Self.minGap + c * (Self.scatterGap - Self.minGap), radius: radius, passes: 40)
  }
}

/// A tiny deterministic generator (SplitMix64), so each dot's scatter is the same on every frame and every run.
private struct SplitMix {
  var state: UInt64

  init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x2545_F491_4F6C_DD1D }

  mutating func unit() -> CGFloat {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return CGFloat(z >> 11) / CGFloat(1 << 53)
  }
}

#Preview("Rating dial") {
  HStack(spacing: Theme.Spacing.s) {
    ForEach([0, 0.25, 0.5, 0.76, 1], id: \.self) { value in
      RatingDial(value: value, radius: 108).scaleEffect(0.3).frame(width: 80, height: 80)
    }
  }
  .padding()
  .background(Theme.background)
}
