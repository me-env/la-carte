@testable import APIClient
import ComposableArchitecture
import Foundation
import Testing
import UIKit

@testable import DesignSystem
@testable import StudyFeature

/// Spec 019: any-direction rating drag, the dial's stages, the rating row's echo and the text fade.
@MainActor
struct StudyDragTests {
  let cards = [Card].fixtures

  @Test func theFractionIsTheDragProjectedOnTheUpRightDiagonal() {
    let positive = [CGSize(width: 46, height: 0), CGSize(width: 0, height: -46), CGSize(width: 32.5, height: -32.5)]
    for translation in positive {
      let f = StudyFeature.swipeFraction(translation: translation, cardWidth: 370)
      #expect(f >= 0.124 && f <= 0.125, "\(translation) → \(f)")
    }
    let negative = [CGSize(width: -46, height: 0), CGSize(width: 0, height: 46), CGSize(width: -32.5, height: 32.5)]
    for translation in negative {
      let f = StudyFeature.swipeFraction(translation: translation, cardWidth: 370)
      #expect(f >= -0.125 && f <= -0.124, "\(translation) → \(f)")
    }
    #expect(StudyFeature.swipeFraction(translation: CGSize(width: -40, height: -40), cardWidth: 370) == 0)
    #expect(StudyFeature.swipeFraction(translation: CGSize(width: 40, height: 40), cardWidth: 370) == 0)
    #expect(abs(StudyFeature.swipeFraction(translation: CGSize(width: 200, height: 0), cardWidth: 370) - 0.54) < 0.001)
    #expect(StudyFeature.swipeFraction(translation: CGSize(width: 46, height: 0), cardWidth: 0) == 0)
  }

  @Test func upRightAndUpRightRateUpDownLeftAndDownLeftRateDownTheOtherDiagonalsNothing() {
    let width = 370.0
    // Unit directions in screen points (y down).
    let up = [(1.0, 0.0), (0, -1), (0.5.squareRoot(), -0.5.squareRoot())]
    let down = [(-1.0, 0.0), (0, 1), (-0.5.squareRoot(), 0.5.squareRoot())]
    let across = [(-0.5.squareRoot(), -0.5.squareRoot()), (0.5.squareRoot(), 0.5.squareRoot())]
    let cases: [(Double, [(Double, Double)], Rating?)] = [
      (0.13, up, .good), (0.24, up, .easy), (0.13, down, .hard), (0.24, down, .again),
      (0.05, across, nil), (0.13, across, nil), (0.24, across, nil), (0.6, across, nil),
    ]
    for (length, directions, expected) in cases {
      for (x, y) in directions {
        let translation = CGSize(width: x * length * width, height: y * length * width)
        let f = StudyFeature.swipeFraction(translation: translation, cardWidth: width)
        let rating = StudyFeature.rating(forEase: StudyFeature.ease(forSwipe: f))
        #expect(rating == expected, "\(length) toward (\(x), \(y))")
      }
    }
  }

  @Test func aFittingCardBeginsTheDragInAnyDirection() {
    for velocity in [CGPoint(x: 0, y: 100), CGPoint(x: 0, y: -100), CGPoint(x: 50, y: 100), CGPoint(x: -100, y: 0)] {
      #expect(RatingPan.shouldBegin(velocity: velocity, isScrollable: false), "\(velocity)")
    }
  }

  @Test func aScrollingCardLeavesMovesWithin30DegreesOfVerticalToTheScrollView() {
    for velocity in [CGPoint(x: 0, y: 100), CGPoint(x: 0, y: -100), CGPoint(x: 50, y: 100), CGPoint(x: -50, y: -100)] {
      #expect(!RatingPan.shouldBegin(velocity: velocity, isScrollable: true), "\(velocity)")
    }
    let begins = [
      CGPoint(x: 100, y: 0), CGPoint(x: -100, y: 0), CGPoint(x: 70, y: -70), CGPoint(x: -70, y: -70),
      CGPoint(x: 60, y: 100), CGPoint(x: -60, y: -100),
    ]
    for velocity in begins {
      #expect(RatingPan.shouldBegin(velocity: velocity, isScrollable: true), "\(velocity)")
    }
  }

  @Test func theCardsScrollViewWaitsForTheRatingPanToDecide() {
    let card = UIView()
    let scrollView = UIScrollView()
    card.addSubview(scrollView)
    let pan = UIPanGestureRecognizer()
    card.addGestureRecognizer(pan)
    let coordinator = RatingPan.Coordinator()
    #expect(coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: scrollView.panGestureRecognizer))
    let tap = UITapGestureRecognizer()
    scrollView.addGestureRecognizer(tap)
    #expect(!coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: tap))
    #expect(!coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: UIScrollView().panGestureRecognizer))
  }

  @Test func theDialStageChangesExactlyWhereTheGradeDoes() {
    for i in 0...200 {
      let value = Double(i) / 200
      let stage = RatingDialLayout(value: value).stage
      let expected: RatingDialLayout.Stage =
        switch StudyFeature.rating(forEase: value) {
        case nil: .none
        case .hard, .good: .first
        case .again, .easy: .second
        }
      #expect(stage == expected, "value \(value)")
    }
  }

  @Test func theRowEchoesTheHeldGradeOnItsSide() {
    var state = revealed()
    #expect(state.rowEcho == nil)
    let expected: [(Double, StudyFeature.State.RowEcho?)] = [
      (0, nil),
      (0.04, .init(rating: .good, isArmed: false)),
      (0.13, .init(rating: .good, isArmed: true)),
      (0.24, .init(rating: .easy, isArmed: true)),
      (-0.04, .init(rating: .hard, isArmed: false)),
      (-0.13, .init(rating: .hard, isArmed: true)),
      (-0.24, .init(rating: .again, isArmed: true)),
    ]
    for (fraction, echo) in expected {
      state.swipeEase = StudyFeature.ease(forSwipe: fraction)
      #expect(state.rowEcho == echo, "f = \(fraction)")
    }
  }

  @Test func theCardTextFadesTo30PercentAcrossTheDeadZone() {
    var state = revealed()
    #expect(state.cardTextOpacity == 1)
    let expected: [(Double, Double)] = [(0, 1), (0.0375, 0.65), (-0.0375, 0.65), (0.075, 0.3), (0.24, 0.3)]
    for (fraction, opacity) in expected {
      state.swipeEase = StudyFeature.ease(forSwipe: fraction)
      #expect(abs(state.cardTextOpacity - opacity) < 1e-9, "f = \(fraction)")
    }
  }

  @Test func theReleasedGradeStaysOnTheRowUntilTheNextCard() async {
    let store = TestStore(initialState: revealed()) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.stats = { .plain }
      $0.apiClient.review = { _, _ in cards[0] }
    }

    await store.send(.swipeChanged(fraction: 0.24)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: 0.24)
    }
    await store.send(.swipeEnded(fraction: 0.24)) {
      $0.swipeEase = nil
      $0.releasedRating = .easy
      $0.isReviewing = true
    }
    #expect(store.state.rowEcho == .init(rating: .easy, isArmed: true))
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.releasedRating = nil
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
    await store.receive(\.ladderResponse) {
      $0.ladder = Ladder(stats: .plain)
    }
    #expect(store.state.rowEcho == nil)
  }

  @Test func aCancelledDragLeavesTheRowAtRest() async {
    let store = TestStore(initialState: revealed()) { StudyFeature() }

    await store.send(.swipeChanged(fraction: -0.04)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: -0.04)
    }
    await store.send(.swipeEnded(fraction: -0.04)) {
      $0.swipeEase = nil
    }
    #expect(store.state.rowEcho == nil)
    #expect(store.state.cardTextOpacity == 1)
  }

  private func revealed() -> StudyFeature.State {
    var state = StudyFeature.State()
    state.cards = IdentifiedArray(uniqueElements: cards)
    state.phase = .studying
    state.isRevealed = true
    return state
  }
}
