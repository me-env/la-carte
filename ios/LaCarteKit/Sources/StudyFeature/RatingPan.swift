import SwiftUI
import UIKit

/// The rating drag's pan (spec 019). On a card that fits it begins in any direction; on a card that scrolls, a
/// first movement within 30° of vertical is left to the scroll view. Once begun, it reports the full translation.
struct RatingPan: UIGestureRecognizerRepresentable {
  var isEnabled: Bool
  var isScrollable: Bool
  /// The touch-down point (local coordinates) and the translation so far.
  var onChange: (_ start: CGPoint, _ translation: CGSize) -> Void
  /// The final translation; zero when the system cancels the pan, which cancels the rating.
  var onEnd: (_ translation: CGSize) -> Void

  /// `|dx| ≥ 0.58·|dy|` is outside 30° of vertical (tan 30° ≈ 0.58).
  static func shouldBegin(velocity: CGPoint, isScrollable: Bool) -> Bool {
    !isScrollable || abs(velocity.x) >= 0.58 * abs(velocity.y)
  }

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

  func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
    let pan = UIPanGestureRecognizer()
    pan.delegate = context.coordinator
    pan.isEnabled = isEnabled
    context.coordinator.isScrollable = isScrollable
    return pan
  }

  func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
    recognizer.isEnabled = isEnabled
    context.coordinator.isScrollable = isScrollable
  }

  func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
    let translation = recognizer.translation(in: recognizer.view)
    let size = CGSize(width: translation.x, height: translation.y)
    switch recognizer.state {
    case .began, .changed:
      let location = context.converter.localLocation
      onChange(CGPoint(x: location.x - translation.x, y: location.y - translation.y), size)
    case .ended:
      onEnd(size)
    case .cancelled, .failed:
      onEnd(.zero)
    default:
      break
    }
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var isScrollable = false

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
      return RatingPan.shouldBegin(velocity: pan.velocity(in: pan.view), isScrollable: isScrollable)
    }
  }
}
