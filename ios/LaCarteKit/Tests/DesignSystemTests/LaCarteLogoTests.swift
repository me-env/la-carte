import SwiftUI
import Testing

@testable import DesignSystem

struct LaCarteLogoTests {
  @Test func fullProgressIsTheFinalMark() {
    let geometry = LogoGeometry(progress: 1)
    #expect(geometry.cardOpacity == 1)
    #expect(geometry.cardScale == 1)
    #expect(geometry.lineTrim == 1)
  }

  @Test func zeroProgressShowsNothing() {
    let geometry = LogoGeometry(progress: 0)
    #expect(geometry.cardOpacity == 0)
    #expect(geometry.cardBody.isEmpty && geometry.lineOutside.isEmpty)
  }

  @Test func theCardSettlesBeforeTheCurveIsDrawn() {
    let card = LogoGeometry(progress: LogoGeometry.linePhase.lowerBound)
    #expect(card.cardOpacity == 1 && card.cardScale == 1)
    #expect(card.line.isEmpty)
  }

  @Test func progressIsClamped() {
    #expect(LogoGeometry(progress: -1) == LogoGeometry(progress: 0))
    #expect(LogoGeometry(progress: 2) == LogoGeometry(progress: 1))
  }

  @Test func drawInIsMonotonic() {
    var previous = LogoGeometry(progress: 0)
    for step in 1...20 {
      let geometry = LogoGeometry(progress: Double(step) / 20)
      #expect(geometry.cardOpacity >= previous.cardOpacity)
      #expect(geometry.cardScale >= previous.cardScale)
      #expect(geometry.lineTrim >= previous.lineTrim)
      previous = geometry
    }
  }

  /// The chosen mark: decay 1 falls outside the card (pink), the reset sits on the card's left edge, and decay 2 runs
  /// inside the card (cut out) and ends before its right edge.
  @Test func theLineCrossesTheCard() {
    let card = LogoGeometry.card
    let curve = LogoGeometry.curve
    let resetTop = curve[LogoGeometry.resetTop]
    #expect(curve.first!.x < card.minX && card.contains(curve.last!))
    #expect(abs(resetTop.x - card.minX) < 0.01)
    #expect(abs(LogoGeometry.bar.midX - card.minX) < 0.01)

    let geometry = LogoGeometry(progress: 1)
    let first = curve.first!
    let inside = curve[LogoGeometry.resetTop + 2]
    #expect(card.contains(inside))
    #expect(geometry.lineOutside.contains(first))  // pink outside the card
    #expect(!geometry.cardBody.contains(inside))  // cut out inside it
    #expect(geometry.cardBody.contains(CGPoint(x: card.midX, y: card.maxY - 10)))  // the card below the curve
  }

  @Test func theResetBarRisesWhileTheTrimRunsUpTheReset() {
    let range = LogoGeometry.resetRange
    #expect(range.lowerBound > 0 && range.upperBound < 1)
    let foot = CGPoint(x: LogoGeometry.bar.midX, y: LogoGeometry.bar.maxY - 2)
    let head = CGPoint(x: LogoGeometry.bar.minX + 2, y: LogoGeometry.bar.minY + 4)
    let before = LogoGeometry.rising(LogoGeometry.bar, radius: LogoGeometry.barRadius, rise: 0.1)
    #expect(before.contains(foot) && !before.contains(head))
    let after = LogoGeometry.rising(LogoGeometry.bar, radius: LogoGeometry.barRadius, rise: 1)
    #expect(after.boundingRect == LogoGeometry.bar)
  }

  @Test func markFillsItsBoxAndIsCentered() {
    let geometry = LogoGeometry(progress: 1)
    let bounds = geometry.cardBody.boundingRect.union(geometry.lineOutside.boundingRect)
    #expect(bounds.minX >= -0.01 && bounds.minY >= -0.01 && bounds.maxX <= 100.01 && bounds.maxY <= 100.01)
    #expect(abs(bounds.midX - 50) <= 0.5)
    #expect(abs(bounds.midY - 50) <= 0.5)
  }
}
