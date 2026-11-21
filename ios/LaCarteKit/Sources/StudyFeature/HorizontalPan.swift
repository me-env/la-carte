import SwiftUI
import UIKit

/// A pan that begins only when the first movement is mostly horizontal, so the card's scroll view and
/// pull-to-refresh keep every vertical gesture (spec 011). Only the horizontal translation is reported.
struct HorizontalPan: UIGestureRecognizerRepresentable {
  var isEnabled: Bool
  /// The touch-down point (local coordinates) and the horizontal translation so far.
  var onChange: (_ start: CGPoint, _ translation: CGFloat) -> Void
  /// The final horizontal translation; 0 when the system cancels the pan, which cancels the rating.
  var onEnd: (_ translation: CGFloat) -> Void

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

  func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
    let pan = UIPanGestureRecognizer()
    pan.delegate = context.coordinator
    pan.isEnabled = isEnabled
    return pan
  }

  func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
    recognizer.isEnabled = isEnabled
  }

  func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
    let translation = recognizer.translation(in: recognizer.view)
    switch recognizer.state {
    case .began, .changed:
      let location = context.converter.localLocation
      onChange(CGPoint(x: location.x - translation.x, y: location.y - translation.y), translation.x)
    case .ended:
      onEnd(translation.x)
    case .cancelled, .failed:
      onEnd(0)
    default:
      break
    }
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
      let velocity = pan.velocity(in: pan.view)
      return abs(velocity.x) > abs(velocity.y)
    }
  }
}
