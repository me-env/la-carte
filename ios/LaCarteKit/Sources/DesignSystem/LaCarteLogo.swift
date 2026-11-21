import SwiftUI

/// The la-carte mark: two portrait cards fanned like playing cards. The front one carries a word (a pink line,
/// the accent's main use) and its answer (a grey line). Drawn from shapes in a 100×100 box, so it scales to any
/// size and uses the theme's tokens. The same numbers are in `docs/design/brand/render.sh`; keep them in sync.
///
/// `progress` draws it in (0 = nothing, 1 = the full mark) and is animatable, so it works as a launch mark
/// (`LaCarteLaunchMark`), a loading mark (`LaCarteLoadingMark`) and inside `matchedGeometryEffect`.
public struct LaCarteLogo: View, Animatable {
  nonisolated public var progress: Double

  public init(progress: Double = 1) {
    self.progress = progress
  }

  /// `nonisolated`: `Animatable` isn't main-actor isolated, but `View` makes the struct `@MainActor`.
  nonisolated public var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  public var body: some View {
    let geometry = LogoGeometry(progress: progress)
    ZStack {
      UnitShape(path: geometry.backCard)
        .fill(Theme.secondaryInk)
      UnitShape(path: geometry.frontCard)
        .fill(Theme.ink)
      UnitShape(path: geometry.wordLine)
        .fill(Theme.accentOnInk)
      UnitShape(path: geometry.answerLine)
        .fill(Theme.secondaryInk)
    }
    .opacity(geometry.opacity)
    .aspectRatio(1, contentMode: .fit)
    .accessibilityElement()
    .accessibilityLabel("la carte")
    .accessibilityAddTraits(.isImage)
  }
}

/// The logo's geometry in a 100×100 box, as a pure function of `progress` (tested in `LaCarteLogoTests`).
struct LogoGeometry: Equatable {
  /// Both cards, portrait like a playing card, before they're fanned.
  static let card = CGRect(x: 24, y: 17, width: 46, height: 64)
  static let cardRadius: CGFloat = 8
  /// The fan turns both cards about this point (bottom center of the card).
  static let pivot = CGPoint(x: 47, y: 81)
  static let frontAngle = -6.0
  static let backAngle = 12.0
  /// Transparent gap around the front card, so the two cards stay apart at small sizes.
  static let gap: CGFloat = 2
  /// The word (pink) and its answer (grey), left-aligned on the front card.
  static let word = CGRect(x: 32, y: 39, width: 26, height: 6)
  static let answer = CGRect(x: 32, y: 51, width: 16, height: 6)

  var opacity: Double
  var frontScale: Double
  /// The back card's angle in degrees: starts hidden behind the front card, ends fanned out.
  var backAngle: Double
  var wordWidth: CGFloat
  var answerWidth: CGFloat

  init(progress: Double) {
    let p = min(max(progress, 0), 1)
    // 0–0.35: the card fades and settles in. 0.3–0.7: the next card fans out. 0.6–1: the word, then the answer.
    let appear = Self.ease(p, 0, 0.35)
    opacity = appear
    frontScale = 0.9 + 0.1 * appear
    backAngle = Self.frontAngle + (Self.backAngle - Self.frontAngle) * Self.ease(p, 0.3, 0.7)
    wordWidth = Self.word.width * Self.ease(p, 0.6, 0.85)
    answerWidth = Self.answer.width * Self.ease(p, 0.75, 1)
  }

  /// Smoothstep of `p` between `start` and `end`.
  static func ease(_ p: Double, _ start: Double, _ end: Double) -> Double {
    let t = min(max((p - start) / (end - start), 0), 1)
    return t * t * (3 - 2 * t)
  }

  var frontCard: Path {
    Path(roundedRect: Self.card, cornerRadius: Self.cardRadius, style: .continuous).applying(frontTransform)
  }

  /// The back card, minus the front card and the gap around it.
  var backCard: Path {
    let front = frontCard
    let cutout = front.union(front.strokedPath(StrokeStyle(lineWidth: Self.gap * 2, lineJoin: .round)))
    return Path(roundedRect: Self.card, cornerRadius: Self.cardRadius, style: .continuous)
      .applying(Self.rotation(backAngle))
      .subtracting(cutout)
  }

  var wordLine: Path { line(Self.word, width: wordWidth) }
  var answerLine: Path { line(Self.answer, width: answerWidth) }

  /// A line written from its left end; empty until it starts.
  private func line(_ rect: CGRect, width: CGFloat) -> Path {
    guard width > 0 else { return Path() }
    let written = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
    return Path(roundedRect: written, cornerRadius: rect.height / 2).applying(frontTransform)
  }

  /// The front card's fan angle, then its settle-in scale about its center (the lines move with it).
  private var frontTransform: CGAffineTransform {
    let center = CGPoint(x: Self.card.midX, y: Self.card.midY)
    let scale = CGAffineTransform(translationX: center.x, y: center.y)
      .scaledBy(x: frontScale, y: frontScale)
      .translatedBy(x: -center.x, y: -center.y)
    return Self.rotation(Self.frontAngle).concatenating(scale)
  }

  static func rotation(_ degrees: Double) -> CGAffineTransform {
    CGAffineTransform(translationX: pivot.x, y: pivot.y)
      .rotated(by: degrees * .pi / 180)
      .translatedBy(x: -pivot.x, y: -pivot.y)
  }
}

/// Draws a path from the 100×100 logo box, scaled to fit and centered in the given rect.
private struct UnitShape: Shape {
  let path: Path

  func path(in rect: CGRect) -> Path {
    let side = min(rect.width, rect.height)
    let transform = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
      .scaledBy(x: side / 100, y: side / 100)
    return path.applying(transform)
  }
}

/// The logo drawing itself in once, e.g. on a launch or empty screen. With Reduce Motion it only fades in.
public struct LaCarteLaunchMark: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var progress = 0.0
  @State private var opacity = 0.0

  public init() {}

  public var body: some View {
    LaCarteLogo(progress: reduceMotion ? 1 : progress)
      .opacity(reduceMotion ? opacity : 1)
      .onAppear {
        withAnimation(reduceMotion ? Theme.Motion.standard : Theme.Motion.logoDrawIn) {
          progress = 1
          opacity = 1
        }
      }
  }
}

/// The logo as a loading indicator: the word and its answer are written and erased, slowly.
/// With Reduce Motion the whole mark dims and brightens instead (no movement).
public struct LaCarteLoadingMark: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init() {}

  public var body: some View {
    Group {
      if reduceMotion {
        LaCarteLogo()
          .phaseAnimator([1.0, 0.4]) { logo, opacity in
            logo.opacity(opacity)
          } animation: { _ in Theme.Motion.loadingPulse }
      } else {
        // 0.6 → 1 is the word and answer being written (see `LogoGeometry`).
        PhaseAnimator([1.0, 0.6]) { progress in
          LaCarteLogo(progress: progress)
        } animation: { _ in Theme.Motion.loadingPulse }
      }
    }
    .accessibilityLabel("Loading")
  }
}

#Preview("Logo") {
  VStack(spacing: Theme.Spacing.l) {
    HStack(spacing: Theme.Spacing.m) {
      LaCarteLogo().frame(width: 29, height: 29)
      LaCarteLogo().frame(width: 64, height: 64)
      LaCarteLogo().frame(width: 120, height: 120)
    }
    LaCarteLaunchMark().frame(width: 120, height: 120)
    LaCarteLoadingMark().frame(width: 64, height: 64)
  }
  .padding()
  .background(Theme.background)
}
