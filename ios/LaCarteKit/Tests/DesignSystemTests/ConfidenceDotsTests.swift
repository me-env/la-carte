import Foundation
import Testing

@testable import DesignSystem

struct ConfidenceDotsTests {
  @Test func fullOrderIsARegularRingOfEqualDots() {
    let dots = DotRing(order: 1).dots
    #expect(dots.count == DotRing.count)
    for (index, dot) in dots.enumerated() {
      let angle = 2 * Double.pi * Double(index) / Double(DotRing.count)
      #expect(abs(dot.center.x - cos(angle)) < 1e-9)
      #expect(abs(dot.center.y - sin(angle)) < 1e-9)
      #expect(dot.scale == 1)
    }
  }

  @Test func theSameOrderAlwaysDrawsTheSameDots() {
    for order in [0, 0.25, 0.5, 0.75, 1] {
      #expect(DotRing(order: order) == DotRing(order: order))
    }
  }

  @Test func lessOrderMeansMoreScatter() {
    func scatter(_ order: Double) -> Double {
      DotRing(order: order).dots.reduce(0) { $0 + abs(hypot($1.center.x, $1.center.y) - 1) + abs($1.scale - 1) }
    }
    #expect(scatter(0) > scatter(0.25))
    #expect(scatter(0.25) > scatter(0.5))
    #expect(scatter(0.5) > scatter(0.75))
    #expect(scatter(0.75) > scatter(1))
  }

  @Test func orderIsClampedAndDotsStayReadable() {
    #expect(DotRing(order: -1) == DotRing(order: 0))
    #expect(DotRing(order: 2) == DotRing(order: 1))
    #expect(DotRing(order: 0).dots.allSatisfy { DotRing.dotDiameter * $0.scale >= 4 })
  }
}
