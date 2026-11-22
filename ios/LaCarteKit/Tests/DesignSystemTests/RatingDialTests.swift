import Foundation
import Testing

@testable import DesignSystem

struct RatingDialTests {
  /// Where dot `i` sits when fully ordered: evenly spaced on its ring.
  func latticePoint(_ i: Int, radius: CGFloat = 108) -> (x: CGFloat, y: CGFloat) {
    let (ring, j, n) = RatingDialLayout.slot(i)
    let angle = (Double(j) + (ring == 1 ? 0.5 : 0)) * 2 * .pi / Double(n)
    let r = radius * RatingDialLayout.ringScale[ring]
    return (r * sin(angle), -r * cos(angle))
  }

  @Test func easyIsMirrorSymmetric() {
    let dots = RatingDialLayout(value: 1).dots
    for dot in dots {
      let hasMirror = dots.contains { abs($0.x + dot.x) < 1e-6 && abs($0.y - dot.y) < 1e-6 }
      #expect(hasMirror)
    }
  }

  @Test func orderedRingsHaveTheSameSpacingAlongEveryRing() {
    #expect(RatingDialLayout.ringCounts == [29, 32, 35])
    let pitches = zip(RatingDialLayout.ringCounts, RatingDialLayout.ringScale).map { n, scale in
      2 * .pi * 108 * scale / CGFloat(n)
    }
    #expect(pitches.max()! - pitches.min()! < 0.3)
    let dots = RatingDialLayout(value: 1).dots
    #expect(abs(hypot(dots[1].x - dots[0].x, dots[1].y - dots[0].y) - pitches[0]) < 0.1)
  }

  func distanceFromLattice(_ layout: RatingDialLayout) -> CGFloat {
    layout.dots.enumerated().map { i, dot in
      let p = latticePoint(i)
      return hypot(dot.x - p.x, dot.y - p.y)
    }.max() ?? 0
  }

  func sizeSpread(_ layout: RatingDialLayout) -> CGFloat {
    let sizes = layout.dots.map(\.diameter)
    return (sizes.max() ?? 0) - (sizes.min() ?? 0)
  }

  @Test func ninetySixDots() {
    #expect(RatingDialLayout(value: 0.5).dots.count == 96)
  }

  @Test(arguments: [0.875, 1.0])
  func easyIsFullyOrderedOnThreeEvenRingsAllOneSize(value: Double) {
    let layout = RatingDialLayout(value: value)
    #expect(layout.stage == .second)
    #expect(layout.disorder == 0)
    #expect(distanceFromLattice(layout) < 1e-9)
    #expect(sizeSpread(layout) == 0)
    #expect(layout.dots[0].diameter == RatingDialLayout.diameter)
  }

  @Test(arguments: [0.125, 0.0])
  func forgotIsFullyScatteredWithVariedSizes(value: Double) {
    let layout = RatingDialLayout(value: value)
    #expect(layout.stage == .second)
    #expect(layout.disorder == 1)
    #expect(distanceFromLattice(layout) > 15)
    #expect(sizeSpread(layout) > 3)
  }

  @Test func eachGradeEdgeHasItsDisorder() {
    let edges: [(Double, Double)] = [
      (0.125, RatingDialLayout.forgot), (0.35, RatingDialLayout.hard), (0.5, RatingDialLayout.rest),
      (0.65, RatingDialLayout.gotIt), (0.875, RatingDialLayout.easy),
    ]
    for (value, disorder) in edges {
      #expect(abs(RatingDialLayout(value: value).disorder - disorder) < 1e-9, "value \(value)")
    }
    #expect(RatingDialLayout(value: 0.35).stage == .first)
    #expect(RatingDialLayout(value: 0.65).stage == .first)
    #expect(RatingDialLayout(value: 0.5).stage == .none)
  }

  @Test func disorderFallsSteadilyFromForgotToEasy() {
    var previous = 2.0
    for step in 0...200 {
      let layout = RatingDialLayout(value: Double(step) / 200)
      #expect(layout.disorder <= previous + 1e-12, "value \(Double(step) / 200)")
      previous = layout.disorder
    }
  }

  func smallestGap(_ dots: [RatingDialLayout.Dot]) -> CGFloat {
    var smallest = CGFloat.infinity
    for i in dots.indices {
      for j in dots.indices where j > i {
        let gap = hypot(dots[i].x - dots[j].x, dots[i].y - dots[j].y) - (dots[i].diameter + dots[j].diameter) / 2
        smallest = min(smallest, gap)
      }
    }
    return smallest
  }

  @Test func noTwoDotsEverTouch() {
    for step in 0...20 {
      let value = Double(step) / 20
      #expect(smallestGap(RatingDialLayout(value: value).dots) >= RatingDialLayout.minGap - 0.05, "value \(value)")
    }
  }

  @Test func theScatterIsEvenAndHasNoBigVoids() {
    let dots = RatingDialLayout(value: 0).dots
    #expect(smallestGap(dots) >= RatingDialLayout.scatterGap - 0.05)
    // No empty sector wider than two dot pitches.
    let angles = dots.map { atan2($0.x, -$0.y) }.sorted()
    let gaps = zip(angles.dropFirst(), angles).map { $0 - $1 } + [angles[0] + 2 * .pi - angles[angles.count - 1]]
    #expect(gaps.max()! <= 2 * 2 * .pi / 32)  // two pitches of the middle ring
  }

  @Test func theScatterStaysClearOfTheCardText() {
    let nearest = RatingDialLayout(value: 0).dots.map { hypot($0.x, $0.y) }.min()!
    #expect(nearest >= 108 * 0.66)
  }

  @Test func eachGradeHoldsItsLookDeepInItsBin() {
    #expect(RatingDialLayout(value: 0.25).disorder == RatingDialLayout.hard)
    #expect(RatingDialLayout(value: 0.8).disorder == RatingDialLayout.gotIt)
    #expect(RatingDialLayout(value: 0.45).disorder == RatingDialLayout.rest)
  }

  @Test func theScatterIsDeterministic() {
    #expect(RatingDialLayout(value: 0.2) == RatingDialLayout(value: 0.2))
  }

  @Test func theFrameHoldsEveryDotAndItsPulse() {
    let radius: CGFloat = 108
    let extent = RatingDialLayout.extent(radius: radius)
    for value in [0.0, 0.25, 0.5] {
      for dot in RatingDialLayout(value: value, radius: radius).dots {
        #expect(hypot(dot.x, dot.y) + dot.diameter * 1.3 / 2 <= extent)
      }
    }
  }
}
