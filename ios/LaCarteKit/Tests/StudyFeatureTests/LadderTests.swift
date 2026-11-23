import APIClient
import Testing

@testable import StudyFeature

/// Spec 021's ladder: the mockup states (AC 14), the edge rows (AC 15) and the step notices (AC 16).
struct LadderTests {
  /// Rows as "label done/total", or "label ✓" when done.
  func rows(_ ladder: Ladder) -> [String] {
    ladder.rows.map { $0.isDone ? "\($0.label) ✓" : "\($0.label) \($0.done)/\($0.total)" }
  }

  func counter(_ ladder: Ladder) -> String? {
    ladder.counter.map { "\($0.count) \($0.unit)" }
  }

  func ladder(
    atRisk: (Int, Int) = (0, 0), reviews: (Int, Int) = (0, 0), newToday: Int = 0, milestone: Int = 15, dueNew: Int = 0
  ) -> Ladder {
    Ladder(
      stats: DeckStats(
        total: 100, due: 0, new: 0, reviewedToday: 0, nextDue: nil, newToday: newToday, milestone: milestone,
        dueNew: dueNew, atRiskTotal: atRisk.1, atRiskDone: atRisk.0, reviewsTotal: reviews.1, reviewsDone: reviews.0
      )
    )
  }

  @Test func backlogStartsAtRisk() {
    let state = ladder(atRisk: (6, 14), reviews: (6, 52), dueNew: 40)
    #expect(rows(state) == ["At risk 6/14"])
    #expect(counter(state) == "8 at risk")
  }

  @Test func atRiskDoneThenReviews() {
    let state = ladder(atRisk: (14, 14), reviews: (30, 52), dueNew: 40)
    #expect(rows(state) == ["At risk ✓", "Reviews 30/52"])
    #expect(counter(state) == "22 to review")
  }

  @Test func reviewsDoneThenTheFirstNewStep() {
    let state = ladder(atRisk: (14, 14), reviews: (52, 52), newToday: 9, dueNew: 40)
    #expect(rows(state) == ["At risk ✓", "Reviews ✓", "15 new 9/15"])
    #expect(counter(state) == "6 new")
  }

  @Test func manyNewShowsOnlyTheHighestFinishedStep() {
    let state = ladder(atRisk: (14, 14), reviews: (52, 52), newToday: 49, dueNew: 30)
    #expect(rows(state) == ["At risk ✓", "Reviews ✓", "45 new ✓", "60 new 49/60"])
    #expect(counter(state) == "11 new")
  }

  @Test func normalDayHasNoAtRiskRow() {
    let state = ladder(reviews: (12, 20))
    #expect(rows(state) == ["Reviews 12/20"])
    #expect(counter(state) == "8 to review")
  }

  @Test func noNewCardsWaitingShowsTheDaysTotalAndNoCurrentRow() {
    let state = ladder(newToday: 7)
    #expect(rows(state) == ["7 new ✓"])
    #expect(state.current == nil)
    #expect(counter(state) == nil)
  }

  @Test func aFinishedStepWithNewCardsWaiting() {
    let state = ladder(newToday: 15, dueNew: 3)
    #expect(rows(state) == ["15 new ✓", "30 new 15/30"])
    #expect(counter(state) == "3 new")
  }

  @Test func reopenedReviewsHidesTheStepsAfterIt() {
    let state = ladder(atRisk: (14, 14), reviews: (52, 53), newToday: 20, dueNew: 10)
    #expect(rows(state) == ["At risk ✓", "Reviews 52/53"])
    #expect(counter(state) == "1 to review")
  }

  @Test func rowKindsNameTheAccessibilityIdentifiers() {
    let state = ladder(atRisk: (14, 14), reviews: (52, 52), newToday: 49, dueNew: 30)
    #expect(state.rows.map(\.kind.rawValue) == ["atRisk", "reviews", "newDone", "new"])
  }

  @Test func notices() {
    #expect(ladder(atRisk: (14, 14), reviews: (14, 52)).notice(after: ladder(atRisk: (13, 14), reviews: (13, 52))) == "At risk")
    #expect(ladder(atRisk: (14, 14), reviews: (52, 52)).notice(after: ladder(atRisk: (14, 14), reviews: (51, 52))) == "Reviews")
    #expect(ladder(atRisk: (14, 14), reviews: (52, 52)).notice(after: ladder(atRisk: (13, 14), reviews: (51, 52))) == "Reviews")
    #expect(ladder(newToday: 15, dueNew: 5).notice(after: ladder(newToday: 14, dueNew: 6)) == "15 new")
    let same = ladder(atRisk: (3, 14), reviews: (3, 52), newToday: 4, dueNew: 5)
    #expect(same.notice(after: same) == nil)
  }
}
