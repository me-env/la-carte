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

  /// Just after the curve starts the trimmed line is degenerate; it must not turn the card pink (QA logo-131 bug 1).
  @Test(arguments: [1e-7, 5e-7, 1e-6, 3e-6, 7e-6, 1e-5])
  func aJustStartedCurveIsNotTheCard(epsilon: Double) {
    let geometry = LogoGeometry(progress: LogoGeometry.linePhase.lowerBound + epsilon)
    #expect(!Self.coversTheCard(geometry.lineOutside))
    #expect(geometry.cardBody.contains(CGPoint(x: LogoGeometry.card.midX, y: LogoGeometry.card.maxY - 10)))
  }

  /// Every frame of the draw-in, including just past each phase boundary: the pink line never covers the card.
  @Test func theLineNeverCoversTheCard() {
    let line = LogoGeometry.linePhase
    let reset = LogoGeometry.resetRange
    let boundaries = [line.lowerBound] + [reset.lowerBound, reset.upperBound].map {
      line.lowerBound + $0 * (line.upperBound - line.lowerBound)
    }
    let near = boundaries.flatMap { b in [1e-9, 1e-7, 1e-6, 1e-5, 1e-4].flatMap { [b - $0, b + $0] } }
    let sweep = (0...1000).map { Double($0) / 1000 }
    for progress in sweep + near {
      let geometry = LogoGeometry(progress: progress)
      #expect(!Self.coversTheCard(geometry.lineOutside), "progress \(progress)")
      if geometry.cardOpacity > 0 {
        #expect(geometry.cardBody.contains(CGPoint(x: LogoGeometry.card.midX, y: LogoGeometry.card.maxY - 10)), "progress \(progress)")
      }
    }
  }

  /// The lower card is never part of the line, so pink there means the card itself was painted.
  private static func coversTheCard(_ path: Path) -> Bool {
    let card = LogoGeometry.card
    return path.contains(CGPoint(x: card.midX, y: card.maxY - 10)) || path.boundingRect.contains(card)
  }
}
