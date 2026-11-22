import Foundation
import Testing

@testable import DesignSystem

struct RatingDialTests {
  @Test func atTouchDownEveryDotIsTrack() {
    let layout = RatingDialLayout(value: 0.5)
    #expect(layout.dots.count == 24)
    #expect(layout.stage == .none)
    let allMatch = layout.dots.allSatisfy { $0.kind == .track && !$0.isRing }
    #expect(allMatch)
  }

  @Test func theFirstPositiveGradeArmsHalfTheRingAsDiscsClockwise() {
    let layout = RatingDialLayout(value: 0.65)
    #expect(layout.stage == .first)
    let armed = layout.dots.filter { $0.kind == .armed }
    #expect(armed.count == 12)
    let allDiscs = armed.allSatisfy { !$0.isRing }
    #expect(allDiscs)
    let clockwise: [Double] = (0..<12).map { (Double($0) + 0.5) * 15 }
    let angles = armed.map(\.angle)
    #expect(angles == clockwise)
    #expect(armed.first?.angle == 7.5)
  }

  @Test func theFirstNegativeGradeArmsTheSameHalfAsRingsCounterClockwise() {
    let layout = RatingDialLayout(value: 0.35)
    #expect(layout.stage == .first)
    let armed = layout.dots.filter { $0.kind == .armed }
    #expect(armed.count == 12)
    let allRings = armed.allSatisfy(\.isRing)
    #expect(allRings)
    let counterClockwise: [Double] = (0..<12).map { 360 - (Double($0) + 0.5) * 15 }
    let angles = armed.map(\.angle)
    #expect(angles == counterClockwise)
  }

  @Test(arguments: [0.875, 1.0])
  func theSecondPositiveGradeArmsEveryDotAsADisc(value: Double) {
    let layout = RatingDialLayout(value: value)
    #expect(layout.stage == .second)
    let allMatch = layout.dots.allSatisfy { $0.kind == .armed && !$0.isRing }
    #expect(allMatch)
  }

  @Test(arguments: [0.125, 0.0])
  func theSecondNegativeGradeArmsEveryDotAsARing(value: Double) {
    let layout = RatingDialLayout(value: value)
    #expect(layout.stage == .second)
    let allMatch = layout.dots.allSatisfy { $0.kind == .armed && $0.isRing }
    #expect(allMatch)
  }

  @Test func halfwayThroughTheDeadZoneSixDotsArePendingAndNoneArmed() {
    let layout = RatingDialLayout(value: 0.575)  // m = 0.15
    #expect(layout.stage == .none)
    let pendingCount = layout.dots.filter { $0.kind == .pending }.count
    #expect(pendingCount == 6)
    let anyArmed = layout.dots.contains { $0.kind == .armed }
    #expect(!anyArmed)
  }

  @Test func dotStatesHaveTheSpecSizesAndOpacities() {
    let layout = RatingDialLayout(value: 0.50625)  // m = 0.0125: n = 0.5, dot 0 half filled, the others track
    let pending = layout.dots[0]
    #expect(pending.kind == .pending)
    #expect(abs(pending.diameter - 5) < 1e-6)
    #expect(abs(pending.opacity - 0.7) < 1e-6)
    let track = layout.dots[1]
    #expect(track.kind == .track)
    #expect(track.diameter == 4)
    #expect(track.opacity == 0.45)
    let armed = RatingDialLayout(value: 1).dots[0]
    #expect(armed.diameter == 6)
    #expect(armed.opacity == 1)
  }
}
