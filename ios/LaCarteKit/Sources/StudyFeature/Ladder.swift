import APIClient

/// The day's milestone ladder (spec 021): `/stats` arranged as the counter, the popover's rows and the step notices.
/// Display only: it never changes what is served.
struct Ladder: Equatable {
  struct Row: Equatable, Identifiable {
    enum Kind: String {
      case atRisk, reviews, newDone, new
    }

    var kind: Kind
    var label: String
    var done: Int
    var total: Int

    var id: Kind { kind }
    var isDone: Bool { done >= total }
  }

  /// Every step of the day, done or not, in ladder order.
  private let steps: [Row]
  private let newToday: Int
  private let milestone: Int
  private let dueNew: Int

  init(stats: DeckStats) {
    let milestone = max(stats.milestone, 1)
    let finished = stats.newToday / milestone * milestone
    let next = finished + milestone
    var steps: [Row] = []
    if stats.atRiskTotal > 0 {
      steps.append(Row(kind: .atRisk, label: "At risk", done: stats.atRiskDone, total: stats.atRiskTotal))
    }
    if stats.reviewsTotal > 0 {
      steps.append(Row(kind: .reviews, label: "Reviews", done: stats.reviewsDone, total: stats.reviewsTotal))
    }
    if stats.dueNew > 0 {
      if finished > 0 { steps.append(Row(kind: .newDone, label: "\(finished) new", done: finished, total: finished)) }
      steps.append(Row(kind: .new, label: "\(next) new", done: stats.newToday, total: next))
    } else if stats.newToday > 0 {
      steps.append(Row(kind: .newDone, label: "\(stats.newToday) new", done: stats.newToday, total: stats.newToday))
    }
    self.steps = steps
    self.newToday = stats.newToday
    self.milestone = milestone
    self.dueNew = stats.dueNew
  }

  /// The first step that isn't done.
  var current: Row? { steps.first { !$0.isDone } }

  /// The popover's rows: every step up to the current one (a reopened "Reviews" hides the steps after it).
  var rows: [Row] {
    guard let index = steps.firstIndex(where: { !$0.isDone }) else { return steps }
    return Array(steps[...index])
  }

  /// What is left of the current step; nil when every step is done (Study falls back to the batch's count).
  var counter: (count: Int, unit: String)? {
    guard let current else { return nil }
    let left = current.total - current.done
    switch current.kind {
    case .atRisk: return (left, "at risk")
    case .reviews: return (left, "to review")
    case .new, .newDone: return (min(left, dueNew), "new")
    }
  }

  /// The label of the step a rating completed, going from `previous` to this ladder; first match wins (new step,
  /// Reviews, At risk).
  func notice(after previous: Ladder) -> String? {
    if newToday / milestone > previous.newToday / milestone {
      return "\(newToday / milestone * milestone) new"
    }
    for kind in [Row.Kind.reviews, .atRisk] {
      if let before = previous.step(kind), !before.isDone, let after = step(kind), after.isDone {
        return after.label
      }
    }
    return nil
  }

  private func step(_ kind: Row.Kind) -> Row? {
    steps.first { $0.kind == kind }
  }
}
