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

  @Test(arguments: [RatingBands.easy, 1.0])
  func easyIsFullyOrderedOnThreeEvenRingsAllOneSize(value: Double) {
    let layout = RatingDialLayout(value: value)
    #expect(layout.stage == .second)
    #expect(layout.disorder == 0)
    #expect(distanceFromLattice(layout) < 1e-9)
    #expect(sizeSpread(layout) == 0)
    #expect(layout.dots[0].diameter == RatingDialLayout.diameter)
  }

  @Test(arguments: [RatingBands.forgot, 0.0])
  func forgotIsFullyScatteredWithVariedSizes(value: Double) {
    let layout = RatingDialLayout(value: value)
    #expect(layout.stage == .second)
    #expect(layout.disorder == 1)
    #expect(distanceFromLattice(layout) > 15)
    #expect(sizeSpread(layout) > 3)
  }

  @Test func eachGradeEdgeHasItsDisorder() {
    let edges: [(Double, Double)] = [
      (RatingBands.forgot, RatingDialLayout.forgot), (RatingBands.hard, RatingDialLayout.hard),
      (0.5, RatingDialLayout.rest), (RatingBands.gotIt, RatingDialLayout.gotIt), (RatingBands.easy, RatingDialLayout.easy),
    ]
    for (value, disorder) in edges {
      #expect(abs(RatingDialLayout(value: value).disorder - disorder) < 1e-9, "value \(value)")
    }
    #expect(RatingDialLayout(value: RatingBands.hard).stage == .first)
    #expect(RatingDialLayout(value: RatingBands.gotIt).stage == .first)
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
    let (bands, mid) = (RatingBands.self, { (a: Double, b: Double) in (a + b) / 2 })
    #expect(RatingDialLayout(value: mid(bands.forgot, bands.hard)).disorder == RatingDialLayout.hard)
    #expect(RatingDialLayout(value: mid(bands.gotIt, bands.easy)).disorder == RatingDialLayout.gotIt)
    #expect(RatingDialLayout(value: mid(bands.hard, 0.5)).disorder == RatingDialLayout.rest)
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

struct RatingDialRewardTests {
  @Test func gotItSettlesAndEasyBursts() {
    #expect(RatingDial.Release(value: RatingBands.gotIt) == .settle)
    #expect(RatingDial.Release(value: (RatingBands.gotIt + RatingBands.easy) / 2) == .settle)
    #expect(RatingDial.Release(value: RatingBands.easy) == .burst)
    #expect(RatingDial.Release(value: 1) == .burst)
    #expect(RatingDial.Release(value: RatingBands.gotIt - 0.01) == nil)
    #expect(RatingDial.Release(value: 0) == nil)
  }

  @Test(arguments: [RatingDial.Release.settle, .burst])
  func theRewardStartsAsReleasedSettlesThenFadesOutByItsDuration(release: RatingDial.Release) {
    let start = RatingDialReward(release: release, time: 0, reduceMotion: false)
    #expect(start.settle == 0 && start.scale == 1 && start.opacity == 1)
    var previous = -1.0
    for step in 0...60 {
      let settle = RatingDialReward(release: release, time: Double(step) / 100, reduceMotion: false).settle
      #expect(settle >= previous - 1e-12)
      previous = settle
    }
    #expect(RatingDialReward(release: release, time: 0.3, reduceMotion: false).settle == 1)
    let end = RatingDialReward(release: release, time: release.duration(reduceMotion: false), reduceMotion: false)
    #expect(end.opacity == 0)
    #expect(end.scale > 1)
  }

  @Test func easyGrowsMoreAndLastsLongerThanGotIt() {
    let gotIt = RatingDial.Release.settle, easy = RatingDial.Release.burst
    #expect(easy.duration(reduceMotion: false) > gotIt.duration(reduceMotion: false))
    let gotItEnd = RatingDialReward(release: gotIt, time: 0.5, reduceMotion: false)
    let easyEnd = RatingDialReward(release: easy, time: 0.6, reduceMotion: false)
    #expect(easyEnd.scale > gotItEnd.scale)
  }

  @Test func easysRippleRunsOutwardAndItsSecondBeatLandsOnTheOuterRing() {
    func peak(_ ring: Int) -> Double {
      (0...60).map { Double($0) / 100 }.max { a, b in
        RatingDialReward(release: .burst, time: a, reduceMotion: false).ringOffset[ring]
          < RatingDialReward(release: .burst, time: b, reduceMotion: false).ringOffset[ring]
      }!
    }
    #expect(peak(0) < peak(1) && peak(1) < peak(2))
    #expect(abs(peak(2) - RatingDialReward.burstBeat) < 0.011)
    let gotIt = (0...50).map { RatingDialReward(release: .settle, time: Double($0) / 100, reduceMotion: false) }
    #expect(gotIt.allSatisfy { $0.ringOffset == [0, 0, 0] })
  }

  @Test(arguments: [RatingDial.Release.settle, .burst])
  func reduceMotionOnlyFades(release: RatingDial.Release) {
    #expect(release.duration(reduceMotion: true) == 0.15)
    for step in 0...20 {
      let frame = RatingDialReward(release: release, time: Double(step) / 100, reduceMotion: true)
      #expect(frame.settle == 0 && frame.scale == 1 && frame.ringOffset == [0, 0, 0] && frame.ringGrowth == [1, 1, 1])
    }
    #expect(RatingDialReward(release: release, time: 0.15, reduceMotion: true).opacity == 0)
  }

  @Test(arguments: [(RatingDial.Release.settle, 0.7), (.burst, 1.0)])
  func noDotsTouchDuringTheReward(release: RatingDial.Release, value: Double) {
    for step in 0...60 {
      let frame = RatingDialReward(release: release, time: Double(step) / 100, reduceMotion: false)
      let dots = frame.applied(to: RatingDialLayout(value: value, settle: frame.settle).dots)
      var smallest = CGFloat.infinity
      for i in dots.indices {
        for j in dots.indices where j > i {
          smallest = min(
            smallest, hypot(dots[i].x - dots[j].x, dots[i].y - dots[j].y) - (dots[i].diameter + dots[j].diameter) / 2)
        }
      }
      #expect(smallest >= RatingDialLayout.minGap - 0.05, "t \(Double(step) / 100)")
    }
  }
}

/// The grade cues added 2026-11-22 (spec 019 §3 amendment): Forgot's pink share and Easy's chains
/// (Got it's pairs removed the same day: no line before the Got it → Easy midpoint).
struct RatingDialCueTests {
  typealias Layout = RatingDialLayout

  @Test func forgotTurnsAFifthOfTheVisibleDotsPink() {
    #expect(Layout.accentDots.count == 20)
    #expect(Set(Layout.accentDots.map(\.index)).count == 20)
    #expect(Layout.accentDots.allSatisfy { Layout.scatter[$0.index].diameter >= Layout.diameter * 0.8 })
    for value in [0, RatingBands.forgot] {
      let layout = Layout(value: value)
      #expect(layout.blush == 1)
      #expect(Layout.accentDots.allSatisfy { layout.accent(start: $0.start) == 1 }, "value \(value)")
    }
  }

  @Test func onlyForgotIsPink() {
    for step in 0...200 {
      let value = Double(step) / 200
      // Hard (its look held for 70 % of its stretch) and everything above it stays monochrome.
      if value >= RatingBands.forgot + 0.31 * (RatingBands.hard - RatingBands.forgot) { #expect(Layout(value: value).blush == 0, "value \(value)") }
    }
  }

  /// Got it never shows a line: nothing from rest through Got it up to `linkStart` of the way to Easy (at least
  /// the midpoint); the full chains exactly at Easy's bin edge and beyond.
  @Test func noLinksBeforeTheGotItToEasyMidpoint() {
    #expect(Layout.linkStart >= 0.5)
    let (gotIt, easy) = (RatingBands.gotIt, RatingBands.easy)
    let start = gotIt + (easy - gotIt) * Layout.linkStart
    for step in 0...400 {
      let value = Double(step) / 400
      if value < start - 1e-9 { #expect(Layout(value: value).links == 0, "value \(value)") }
    }
    for value in [easy, (easy + 1) / 2, 1] { #expect(Layout(value: value).links == 1, "value \(value)") }
  }

  /// Lines may show in Got it, never connected (user, 2026-11-22): at every ease short of Easy the two halves of every
  /// link stop a clear break apart (≥ 1.5 pt once 1 pt butt caps' antialiasing, half a point each side, eats into
  /// it); from Easy's bin edge on, every link is closed.
  @Test func linksStayOpenUntilEasy() {
    let (gotIt, easy) = (RatingBands.gotIt, RatingBands.easy)
    let values = (0...400).map { gotIt + (easy - gotIt) * Double($0) / 400 }.filter { $0 < easy }
      + [easy.nextDown, easy - 1e-6, easy, (easy + 1) / 2, 1]
    for value in values {
      let layout = Layout(value: value)
      let dots = layout.dots
      var smallest = CGFloat.infinity
      for (i, j) in Layout.ringLinks {
        let length = hypot(dots[j].x - dots[i].x, dots[j].y - dots[i].y)
        func reach(_ k: Int) -> CGFloat {
          Layout.linkReach(length: length, edge: dots[k].diameter / 2, grown: layout.links, joined: layout.linksJoined)
        }
        smallest = min(smallest, length - reach(i) - reach(j))
      }
      if value < easy {
        #expect(smallest - 1 >= 1.5, "value \(value): gap \(smallest)")
      } else {
        #expect(abs(smallest) < 1e-9, "value \(value): gap \(smallest)")
      }
    }
  }

  /// No pop: every cue moves by at most a small step per 0.005 of value, and never backs off toward its grade; the
  /// links grow strictly from their start to Easy.
  @Test func theCuesFollowTheDragContinuously() {
    var previous = Layout(value: 0)
    for step in 1...200 {
      let value = Double(step) / 200
      let layout = Layout(value: value)
      #expect(layout.blush <= previous.blush)
      #expect(layout.links >= previous.links)
      if previous.links > 0 && value <= RatingBands.easy { #expect(layout.links > previous.links, "value \(value)") }
      for (a, b) in [(layout.blush, previous.blush), (layout.links, previous.links)] {
        #expect(abs(a - b) <= 0.15, "value \(value)")
      }
      previous = layout
    }
  }

  /// Easy: each ring closed into one chain, every neighbour pair linked once, never across rings.
  @Test func linksCloseEachRing() {
    let links = Layout.ringLinks
    #expect(links.count == Layout.count)
    #expect(Set(links.map { [$0.0, $0.1].sorted() }).count == Layout.count)
    #expect(links.allSatisfy { Layout.slot($0.0).ring == Layout.slot($0.1).ring })
    var degree = [Int](repeating: 0, count: Layout.count)
    for (i, j) in links { degree[i] += 1; degree[j] += 1 }
    #expect(degree.allSatisfy { $0 == 2 })
  }
}
