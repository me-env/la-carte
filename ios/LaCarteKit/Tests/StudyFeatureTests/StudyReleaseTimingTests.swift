@testable import APIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import DesignSystem
@testable import StudyFeature

/// Spec 019 §6: the release reward is visual only. A Got it / Easy release sends the review and moves to the next card
/// with no wait: the clock never advances here, so any delay tied to the reward's length would hang the receive.
@MainActor
struct StudyReleaseTimingTests {
  let cards = [Card].fixtures

  @Test(arguments: [(0.13, Rating.good), (0.24, .easy)])
  func thePositiveRewardNeverDelaysTheNextCard(fraction: Double, rating: Rating) async {
    let clock = TestClock()
    var state = StudyFeature.State()
    state.cards = IdentifiedArray(uniqueElements: cards)
    state.phase = .studying
    state.isRevealed = true
    let store = TestStore(initialState: state) {
      StudyFeature()
    } withDependencies: { [cards] in
      $0.apiClient.stats = { .plain }
      $0.continuousClock = clock
      $0.apiClient.review = { _, _ in cards[0] }
    }
    // The dial's reward plays for this long; the reducer must not wait for it.
    let release = RatingDial.Release(value: StudyFeature.ease(forSwipe: fraction))
    #expect(release != nil)

    await store.send(.swipeChanged(fraction: fraction)) {
      $0.swipeEase = StudyFeature.ease(forSwipe: fraction)
    }
    await store.send(.swipeEnded(fraction: fraction)) {
      $0.swipeEase = nil
      $0.isReviewing = true
      $0.releasedRating = rating
    }
    await store.receive(\.reviewResponse.success) {
      $0.isReviewing = false
      $0.releasedRating = nil
      $0.isRevealed = false
      $0.cards.removeFirst()
    }
    await store.receive(\.ladderResponse.success) {
      $0.ladder = Ladder(stats: .plain)
    }
    #expect(store.state.cards.first?.id == cards[1].id)
  }

  @Test(arguments: [0.0, 0.13, 0.35, 0.5, 0.64])
  func onlyGotItAndEasyEarnAReward(value: Double) {
    #expect(RatingDial.Release(value: value) == nil)
  }
}
