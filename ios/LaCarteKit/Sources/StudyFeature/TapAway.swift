import SwiftUI
import UIKit

/// While editing inline, a tap or a downward swipe that starts off the edit field ends the edit (spec 010). Decided in
/// UIKit as the touch comes down. As the keyboard comes or goes the card animates, and UIKit hit-tests the layout it
/// is heading to, not the one on screen: a tap on the field as drawn lands behind it. So a touch while the field is
/// still moving never ends the edit. A frame from SwiftUI's geometry callbacks arrives later still, so it can't decide.
struct TapAway: UIGestureRecognizerRepresentable {
  var isEnabled: Bool
  var action: () -> Void

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

  func makeUIGestureRecognizer(context: Context) -> Recognizer {
    let recognizer = Recognizer()
    recognizer.delegate = context.coordinator
    recognizer.cancelsTouchesInView = false
    recognizer.isEnabled = isEnabled
    return recognizer
  }

  func updateUIGestureRecognizer(_ recognizer: Recognizer, context: Context) {
    recognizer.isEnabled = isEnabled
  }

  func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
    if recognizer.state == .ended { action() }
  }

  /// Recognizes as a single touch lifts: a tap (under 10 pt of movement) or a swipe more than 30 pt down.
  final class Recognizer: UIGestureRecognizer {
    private var start: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      super.touchesBegan(touches, with: event)
      guard start == nil, touches.count == 1, let touch = touches.first else {
        state = .failed
        return
      }
      start = touch.location(in: nil)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
      super.touchesEnded(touches, with: event)
      guard let start, let end = touches.first?.location(in: nil) else {
        state = .failed
        return
      }
      let dx = end.x - start.x, dy = end.y - start.y
      state = (abs(dx) < 10 && abs(dy) < 10) || dy > 30 ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
      super.touchesCancelled(touches, with: event)
      state = .failed
    }

    override func reset() {
      super.reset()
      start = nil
    }
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    /// Only a touch UIKit didn't route to the edit field, while the field stands still.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard let window = touch.window, let field = Self.firstResponder(in: window) else { return true }
      let routedToField = touch.view?.isDescendant(of: field) ?? false
      return !routedToField && !Self.isMoving(field)
    }

    private static func firstResponder(in view: UIView) -> UIView? {
      if view.isFirstResponder { return view }
      return view.subviews.lazy.compactMap { firstResponder(in: $0) }.first
    }

    /// Whether the view is drawn away from its layout, i.e. an animation is still moving it into place.
    private static func isMoving(_ view: UIView) -> Bool {
      guard let layer = view.layer.presentation(), let window = view.window?.layer.presentation() else { return false }
      let drawn = layer.convert(layer.bounds, to: window), laidOut = view.convert(view.bounds, to: nil)
      return abs(drawn.minX - laidOut.minX) > 1 || abs(drawn.minY - laidOut.minY) > 1
    }

    /// The scroll view, the field and the buttons keep their own touches.
    func gestureRecognizer(
      _ recognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}
