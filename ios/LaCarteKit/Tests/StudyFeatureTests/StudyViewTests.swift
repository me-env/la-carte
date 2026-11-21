import ComposableArchitecture
import SwiftUI
import Testing
import UIKit

@testable import StudyFeature

/// Between the last rating and "All caught up" the content is empty; the theme must still fill the screen.
@MainActor
struct StudyViewTests {
  @Test func theBackgroundFillsTheScreenWhileTheContentIsEmpty() throws {
    var state = StudyFeature.State()
    state.phase = .studying
    let view = StudyView(store: Store(initialState: state) {})
      .frame(width: 390, height: 844)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    let image = try #require(renderer.cgImage)

    for (x, y) in [(2, 2), (387, 2), (2, 841), (387, 841), (195, 841)] {
      #expect(alpha(of: image, x: x, y: y) == 255, "transparent at (\(x), \(y))")
    }
  }

  private func alpha(of image: CGImage, x: Int, y: Int) -> UInt8 {
    var pixel: [UInt8] = [0, 0, 0, 0]
    let context = CGContext(
      data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return pixel[3]
  }
}
