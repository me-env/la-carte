import SwiftUI

/// The rating drag's grade bands on the ease (0 = full Forgot side, 0.5 = touch-down, 1 = full Easy side; spec 011):
/// the one place they live, so `StudyFeature.rating(forEase:)`, the dial's looks and its cues always agree.
/// Forgot at or below `forgot`, Hard at or below `hard`, nothing below `gotIt`, Got it below `easy`, Easy from it.
public enum RatingBands {
  public static let forgot = 0.03
  public static let hard = 0.35
  public static let gotIt = 0.65
  public static let easy = 0.97
}

/// The dial around the finger during a rating drag (spec 019): 96 dots whose order is the grade. Toward "Got it" /
/// "Easy" they settle into three rings, evenly spaced along each ring, all one size (fully ordered at Easy); toward
/// "Hard" / "Forgot" they scatter, with varied sizes (fully scattered at Forgot). The scatter is seeded per dot, so it
/// never flickers, and follows `value` continuously with no animation of its own. Once a grade is reached the dots
/// turn ink and pulse once. Each outer grade has its own cue on top (2026-11-22): Easy links the dots of each ring
/// into three closed chains (grown in late, past the Got it → Easy midpoint, from both dots' edges; the two halves
/// of every link stay `RatingDialLayout.linkGap` apart until Easy, where they click shut, so no chain ever looks
/// closed on a Got it), Forgot turns a fifth of its dots pink (the accent; Hard stays ink). Drawn in a `Canvas`: one
/// stroked path, one filled path, at most 20 pink fills.
///
/// Released on a positive grade (`release`), the dial plays its reward over the next card, which is already fading
/// in: Got it settles into the rings and fades (0.5 s, success haptic); Easy settles, a ripple runs out through the
/// rings and it fades a little larger (0.6 s, success haptic and a second beat). Reduce Motion: a 0.15 s fade and the
/// haptics, nothing moves. It never takes touches; the caller removes it after `Release.duration`.
public struct RatingDial: View {
  /// The reward a positive release earns.
  public enum Release: Equatable, Sendable {
    case settle, burst

    /// Got it settles, Easy bursts, anything else earns nothing (011's bin edges, on the ease).
    public init?(value: Double) {
      if value >= RatingBands.easy {
        self = .burst
      } else if value >= RatingBands.gotIt {
        self = .settle
      } else {
        return nil
      }
    }

    /// How long the reward lasts; the dial is invisible after it.
    public func duration(reduceMotion: Bool) -> Double {
      reduceMotion ? 0.15 : self == .settle ? 0.5 : 0.6
    }
  }

  let value: Double
  let radius: CGFloat
  let release: Release?
  /// Renders only: the reward at this time instead of the clock.
  var fixedTime: Double?
  @Environment(\.self) private var environment
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulses = 0
  @State private var releasedAt: Date?
  @State private var beats = 0

  /// `value` is the ease 0...1 (0.5 = touch-down; while `release` plays, the ease at release); `radius` is the
  /// distance from the center to the outer ring.
  public init(value: Double, radius: CGFloat, release: Release? = nil) {
    self.value = value
    self.radius = radius
    self.release = release
  }

  public var body: some View {
    TimelineView(.animation(paused: release == nil || fixedTime != nil)) { context in
      let t = fixedTime ?? releasedAt.map { context.date.timeIntervalSince($0) } ?? 0
      let frame = release.map { RatingDialReward(release: $0, time: t, reduceMotion: reduceMotion) } ?? RatingDialReward()
      dots(frame)
        .scaleEffect(frame.scale)
        .opacity(frame.opacity)
    }
    .onChange(of: release) { _, new in releasedAt = new == nil ? nil : .now }
    .sensoryFeedback(.success, trigger: release) { _, new in new != nil }
    .sensoryFeedback(.impact(weight: .heavy), trigger: beats)
    .task(id: release) {
      // Easy's second beat, as the ripple reaches the outer ring.
      guard release == .burst else { return }
      try? await Task.sleep(for: .seconds(RatingDialReward.burstBeat))
      beats += 1
    }
  }

  private func dots(_ frame: RatingDialReward) -> some View {
    let layout = RatingDialLayout(value: value, radius: radius, settle: frame.settle)
    let armed = layout.stage != .none
    let color = (armed ? Theme.ink : Theme.secondaryInk).resolve(in: environment)
    let accent = Theme.accent.resolve(in: environment)
    let side = 2 * RatingDialLayout.extent(radius: radius)
    let placed = frame.applied(to: layout.dots)
    return KeyframeAnimator(initialValue: 1.0, trigger: pulses) { pulse in
      Canvas { context, size in
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        func point(_ i: Int) -> CGPoint { CGPoint(x: center.x + placed[i].x, y: center.y + placed[i].y) }
        func disc(_ i: Int) -> CGRect {
          let d = placed[i].diameter * (armed ? pulse : 1)
          return CGRect(x: point(i).x - d / 2, y: point(i).y - d / 2, width: d, height: d)
        }
        // Links first, under the dots: each grows out of both dots' edges toward its middle, fading in as it grows.
        func grow(_ path: inout Path, from i: Int, to j: Int) {
          let (a, b) = (point(i), point(j))
          let length = max(hypot(b.x - a.x, b.y - a.y), 0.001)
          let (ux, uy) = ((b.x - a.x) / length, (b.y - a.y) / length)
          let edge = min(placed[i].diameter / 2, length / 2)
          let tip = RatingDialLayout.linkReach(
            length: length, edge: placed[i].diameter / 2, grown: CGFloat(layout.links), joined: layout.linksJoined)
          path.move(to: CGPoint(x: a.x + ux * edge, y: a.y + uy * edge))
          path.addLine(to: CGPoint(x: a.x + ux * tip, y: a.y + uy * tip))
        }
        // One weight for every line, its opacity rising with its length to Easy's 60 %.
        if layout.links > 0 {
          var path = Path()
          for (i, j) in RatingDialLayout.ringLinks {
            grow(&path, from: i, to: j)
            grow(&path, from: j, to: i)
          }
          context.stroke(path, with: .color(color.opacity(Self.linkOpacity * layout.links)), lineWidth: Self.linkWidth)
        }
        var discs = Path()
        for i in placed.indices { discs.addEllipse(in: disc(i)) }
        context.fill(discs, with: .color(color))
        if layout.blush > 0 {
          for (i, start) in RatingDialLayout.accentDots {
            let amount = layout.accent(start: start)
            if amount > 0 { context.fill(Path(ellipseIn: disc(i)), with: .color(accent.opacity(amount))) }
          }
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
      if new > old, !reduceMotion, release == nil { pulses += 1 }
    }
  }

  /// The links: hairline-thin, quieter than the dots, so they read as structure, not as a second drawing.
  static let linkWidth: CGFloat = 1
  static let linkOpacity = 0.6
}

/// One frame of a positive release's reward, a pure function of the time since release (tested in
/// `RatingDialTests`, rendered frame by frame in `RenderTests`).
struct RatingDialReward: Equatable {
  /// 0 = the layout as released, 1 = fully ordered.
  var settle = 0.0
  /// Per ring (inner to outer): outward push in points and dot-size factor, for the ripple and the settle's tick.
  var ringOffset: [CGFloat] = [0, 0, 0]
  var ringGrowth: [CGFloat] = [1, 1, 1]
  var scale: CGFloat = 1
  var opacity = 1.0

  /// When Easy's ripple reaches the outer ring: its second haptic beat.
  static let burstBeat = 0.26

  init() {}

  init(release: RatingDial.Release, time t: Double, reduceMotion: Bool) {
    if reduceMotion {
      opacity = 1 - Self.ramp(t, 0, 0.15)
      return
    }
    switch release {
    case .settle:
      // A critically damped settle (no overshoot) done by 0.28 s, a soft tick of every dot as it lands, then the dial
      // grows a little as it fades.
      settle = Self.damped(t, tau: 0.05, end: 0.28)
      let tick = 1 + 0.12 * Self.bump(t, at: 0.24, width: 0.08)
      ringGrowth = [tick, tick, tick]
      let out = Self.ramp(t, 0.28, 0.5)
      scale = 1 + 0.08 * Self.easeOut(out)
      opacity = 1 - out * out
    case .burst:
      // Settles faster, then a ripple runs out through the rings (inner first, 70 ms apart): each ring steps out (3 pt,
      // never touching the next ring; the outer one, with nothing outside it, 6 pt) and its dots swell by 30 %, a
      // bigger event than Got it's tick; then the dial grows more as it fades.
      settle = Self.damped(t, tau: 0.04, end: 0.2)
      for ring in 0..<3 {
        let wave = Self.bump(t, at: 0.12 + 0.07 * Double(ring), width: 0.06)
        ringOffset[ring] = (ring == 2 ? 6 : 3) * wave
        ringGrowth[ring] = 1 + 0.3 * wave
      }
      let out = Self.ramp(t, 0.32, 0.6)
      scale = 1 + 0.15 * Self.easeOut(Self.ramp(t, 0.3, 0.6))
      opacity = 1 - out * out
    }
  }

  /// The layout's dots with each ring's push and growth applied (before `scale` and `opacity`).
  func applied(to dots: [RatingDialLayout.Dot]) -> [RatingDialLayout.Dot] {
    dots.enumerated().map { i, dot in
      let ring = RatingDialLayout.slot(i).ring
      let r = max(hypot(dot.x, dot.y), 0.001)
      let push = (r + ringOffset[ring]) / r
      return .init(x: dot.x * push, y: dot.y * push, diameter: dot.diameter * ringGrowth[ring])
    }
  }

  static func ramp(_ t: Double, _ start: Double, _ end: Double) -> Double {
    min(max((t - start) / (end - start), 0), 1)
  }

  static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

  /// A smooth 0 → 1 → 0 hump centred on `at`, zero outside `at ± width`.
  static func bump(_ t: Double, at center: Double, width: Double) -> CGFloat {
    let x = (t - center) / width
    return abs(x) >= 1 ? 0 : CGFloat(pow(cos(x * .pi / 2), 2))
  }

  /// A critically damped approach to 1, normalised to land exactly at `end`.
  static func damped(_ t: Double, tau: Double, end: Double) -> Double {
    func raw(_ t: Double) -> Double { 1 - (1 + t / tau) * exp(-t / tau) }
    return t >= end ? 1 : max(raw(t), 0) / raw(end)
  }
}

/// The dial's dots as a pure function of the ease (tested in `RatingDialTests`), so the order, the sizes and the
/// grade stages can be checked without drawing.
struct RatingDialLayout: Equatable {
  /// Dots per ring, inner to outer: proportional to the ring's radius, so the spacing along every ring is the
  /// same (~19.3 pt at 108 pt) and the ordered dial reads as smooth rings, not radial spokes.
  static let ringCounts = [29, 32, 35]
  static var count: Int { ringCounts.reduce(0, +) }
  /// Ring radii as fractions of `radius`: inner, middle, outer.
  static let ringScale: [CGFloat] = [0.82, 0.91, 1]
  /// The ordered dot, and the scattered sizes' range as multiples of it.
  static let diameter: CGFloat = 4.5
  static let sizeRange: ClosedRange<CGFloat> = 0.6...1.8
  /// How far a scattered dot may drift along its ring, in dot pitches, and off it, as a fraction of `radius`.
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
  /// Forgot's accent, 0 ... 1: how far `accentDots` have turned pink (0 everywhere but Hard → Forgot).
  var blush: Double
  /// Easy's links (every pair of neighbours along each ring), 0 ... 1: none up to `linkStart`, then grown in to
  /// complete chains at Easy's bin edge, then held.
  var links: Double
  /// Whether the links' halves meet: only from Easy's bin edge on; short of it they stop `linkGap` apart.
  var linksJoined: Bool
  var dots: [Dot]

  /// The dots that turn pink toward Forgot (about a fifth, never the tiniest: a pink speck reads as noise), seeded
  /// like the scatter, each with its start along `blush`, staggered so the share grows in rather than all at once.
  /// Each turns over a short `accentFade`, so few dots are ever half-way (ink and pink blend muddy).
  static let accentCount = 20
  static let accentFade = 0.25
  static let accentDots: [(index: Int, start: Double)] = {
    let picked = (0..<count).filter { scatter[$0].diameter >= diameter * 0.8 }.sorted { a, b in
      var sa = SplitMix(seed: UInt64(a) &+ 1000), sb = SplitMix(seed: UInt64(b) &+ 1000)
      return sa.unit() < sb.unit()
    }.prefix(accentCount)
    return picked.enumerated().map { k, i in (i, (1 - accentFade) * Double(k) / Double(accentCount - 1)) }
  }()

  /// How pink accent dot `start` is at this `blush`, 0 ... 1.
  func accent(start: Double) -> Double { min(max((blush - start) / Self.accentFade, 0), 1) }

  /// Easy's links: every dot to its next neighbour along its ring, closing each ring into a chain (a cross-ring mesh
  /// can't be regular with 29 / 32 / 35 dots).
  static let ringLinks: [(Int, Int)] = (0..<count).map { i in
    let (_, k, n) = slot(i)
    return (i, i - k + (k + 1) % n)
  }

  /// Where Easy's links start, as a fraction of the drag from Got it's bin edge to Easy's: past the midpoint, so
  /// Got it, and anything short of clearly heading to Easy, shows no line at all (user, 2026-11-22).
  static let linkStart = 0.6

  /// The space left between a link's two halves anywhere short of Easy, in points: with 1 pt butt-capped lines and
  /// antialiasing that still reads as a clear break (≥ 1.5 pt), so a chain never looks closed on a Got it (user,
  /// 2026-11-22: lines may appear in Got it "as long as they are not connected").
  static let linkGap: CGFloat = 3

  /// How far one half of a link reaches from its dot's centre toward the other dot, `length` away: from the dot's
  /// `edge`, `grown` (0 ... 1) of the way to its stop, `linkGap / 2` short of the middle, or the middle once `joined`.
  /// Growing to the stop rather than capping keeps the growth gradual to the end; Easy closes the last
  /// `linkGap` at once, the click into the chain.
  static func linkReach(length: CGFloat, edge: CGFloat, grown: CGFloat, joined: Bool) -> CGFloat {
    let edge = min(edge, length / 2)
    let stop = joined ? length / 2 : max(length / 2 - linkGap / 2, edge)
    return edge + grown * (stop - edge)
  }

  /// Half the frame: the outer ring plus the furthest drift, the release ripple (6 pt) and the largest grown dot.
  static func extent(radius: CGFloat) -> CGFloat {
    radius * (1 + radialDrift) + 6 + diameter * sizeRange.upperBound * 1.3 / 2 + 1
  }

  /// Dot `i`'s ring, and its place `j` among that ring's `n` dots (inner ring first).
  static func slot(_ i: Int) -> (ring: Int, j: Int, n: Int) {
    var j = i
    for (ring, n) in ringCounts.enumerated() {
      if j < n { return (ring, j, n) }
      j -= n
    }
    preconditionFailure("dot \(i) out of range")
  }

  /// The middle ring is offset by half a pitch, so the top is staggered (no spoke at 12 o'clock) and every ring is
  /// mirror-symmetric about the vertical axis.
  static func phase(_ ring: Int) -> Double { ring == 1 ? 0.5 : 0 }

  /// Dot `i` fully ordered: evenly spaced on its ring, at `referenceRadius`.
  static func latticePoint(_ i: Int) -> Dot {
    let (ring, j, n) = slot(i)
    let angle = (Double(j) + phase(ring)) * 2 * .pi / Double(n)
    let r = referenceRadius * ringScale[ring]
    return Dot(x: r * sin(angle), y: -r * cos(angle), diameter: diameter)
  }

  /// Every dot fully scattered (Forgot), at `referenceRadius`: a seeded drift and size per dot, then spaced to
  /// `scatterGap`. Computed once.
  static let scatter: [Dot] = {
    let dots = (0..<count).map { i in
      let (ring, j, n) = slot(i)
      let step = 2 * Double.pi / Double(n)
      var seed = SplitMix(seed: UInt64(i))
      let (u1, u2, u3) = (seed.unit(), seed.unit(), seed.unit())
      let angle = (Double(j) + phase(ring) + (2 * u1 - 1) * angleDrift) * step
      let r = referenceRadius * (ringScale[ring] + (2 * u2 - 1) * radialDrift)
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

  init(value: Double, radius: CGFloat = 108, settle: Double = 0) {
    let bands = RatingBands.self
    stage =
      value <= bands.forgot || value >= bands.easy ? .second
      : value <= bands.hard || value >= bands.gotIt ? .first
      : .none
    // Where the drag is on its side, read off the bands: 0 at touch-down, 1 at the first grade's edge (Hard /
    // Got it), 2 at the second's (Forgot / Easy), clamped there.
    let positive = value >= 0.5
    let (first, second) = positive ? (bands.gotIt, bands.easy) : (bands.hard, bands.forgot)
    let unit = { (x: Double) in min(max(x, 0), 1) }
    let p = unit((value - 0.5) / (first - 0.5)) + unit((value - first) / (second - first))
    // Each stretch (dead zone, first grade) holds its own look for 70 % of its travel, then eases into the next one,
    // so a grade reads as itself and not as a blend.
    let (near, far) = positive ? (Self.gotIt, Self.easy) : (Self.hard, Self.forgot)
    func hold(_ from: Double, _ to: Double, _ t: Double) -> Double {
      t < 0.7 ? from : from + (to - from) * min((t - 0.7) / 0.3, 1)
    }
    let disorder = p < 1 ? hold(Self.rest, near, p) : hold(near, far, p - 1)
    self.disorder = disorder
    // Forgot's pink rides the disorder ramp, so it arrives exactly with Forgot's look. Easy's links start late
    // (`linkStart` of the way from Got it to Easy) and ease in and out (smoothstep), so they don't pop in; they
    // stay open by `linkGap` until Easy's bin edge, where they click shut (`linkReach`).
    blush = positive ? 0 : unit((disorder - Self.hard) / (Self.forgot - Self.hard))
    let x = positive ? unit((p - 1 - Self.linkStart) / (1 - Self.linkStart)) : 0
    links = x * x * (3 - 2 * x)
    linksJoined = value >= bands.easy
    let c = CGFloat(disorder * (1 - settle)), k = radius / Self.referenceRadius
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
