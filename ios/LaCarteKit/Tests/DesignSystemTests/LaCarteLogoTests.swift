import SwiftUI
import Testing

@testable import DesignSystem

struct LaCarteLogoTests {
  @Test func fullProgressIsTheFinalMark() {
    let geometry = LogoGeometry(progress: 1)
    #expect(geometry.opacity == 1)
    #expect(geometry.frontScale == 1)
    #expect(geometry.backAngle == LogoGeometry.backAngle)
    #expect(geometry.wordWidth == LogoGeometry.word.width)
    #expect(geometry.answerWidth == LogoGeometry.answer.width)
  }

  @Test func zeroProgressShowsNothing() {
    let geometry = LogoGeometry(progress: 0)
    #expect(geometry.opacity == 0)
    #expect(geometry.wordLine.isEmpty && geometry.answerLine.isEmpty)
    // The next card starts exactly behind the front card.
    #expect(geometry.backAngle == LogoGeometry.frontAngle)
  }

  @Test func progressIsClamped() {
    #expect(LogoGeometry(progress: -1) == LogoGeometry(progress: 0))
    #expect(LogoGeometry(progress: 2) == LogoGeometry(progress: 1))
  }

  @Test func drawInIsMonotonic() {
    var previous = LogoGeometry(progress: 0)
    for step in 1...20 {
      let geometry = LogoGeometry(progress: Double(step) / 20)
      #expect(geometry.opacity >= previous.opacity)
      #expect(geometry.backAngle >= previous.backAngle)
      #expect(geometry.wordWidth >= previous.wordWidth)
      #expect(geometry.answerWidth >= previous.answerWidth)
      previous = geometry
    }
  }

  @Test func linesAreOnTheFrontCardAndNeverOverlapTheNextOne() {
    let geometry = LogoGeometry(progress: 1)
    let front = geometry.frontCard
    for line in [geometry.wordLine, geometry.answerLine] {
      #expect(front.boundingRect.contains(line.boundingRect))
      // Boolean ops can leave zero-area subpaths, so compare areas rather than `isEmpty`.
      let overlap = geometry.backCard.intersection(line).boundingRect
      #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
    }
  }

  @Test func markIsInsideItsBoxAndCentered() {
    let geometry = LogoGeometry(progress: 1)
    let bounds = geometry.frontCard.boundingRect.union(geometry.backCard.boundingRect)
    #expect(bounds.minX > 0 && bounds.minY > 0 && bounds.maxX < 100 && bounds.maxY < 100)
    #expect(abs(bounds.midX - 50) <= 2)
    #expect(abs(bounds.midY - 50) <= 2)
  }
}
