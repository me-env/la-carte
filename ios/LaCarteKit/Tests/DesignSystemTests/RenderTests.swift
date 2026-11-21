import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DesignSystem

/// Renders the logo to PNGs for design reviews (`scripts/design-review.py`).
/// Not the gallery: `ImageRenderer` draws its ScrollView empty.
/// Off by default; `scripts/ios-test.sh --render` turns it on (docs/testing.md).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LA_CARTE_RENDER_DIR"] != nil))
struct RenderTests {
  static let themes: [(name: String, theme: AppTheme, scheme: ColorScheme)] = [
    ("light", .light, .light), ("dark", .dark, .dark), ("forest", .forest, .dark),
  ]

  let directory: URL

  init() throws {
    directory = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["LA_CARTE_RENDER_DIR"] ?? NSTemporaryDirectory()
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  /// 1024 × 1024 px: a 256 pt view at scale 4.
  @Test(arguments: [0.0, 0.25, 0.5, 0.75, 1.0])
  func logo(progress: Double) throws {
    for (name, theme, scheme) in Self.themes {
      let view = LaCarteLogo(progress: progress)
        .frame(width: 256, height: 256)
        .background(Theme.background)
        .environment(\.appTheme, theme)
        .environment(\.colorScheme, scheme)
      let file = String(format: "logo-%@-p%03d.png", name, Int((progress * 100).rounded()))
      try write(view, scale: 4, to: file, expectedPixels: CGSize(width: 1024, height: 1024))
    }
  }

  private func write(_ view: some View, scale: CGFloat, to file: String, expectedPixels: CGSize) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    let image = try #require(renderer.uiImage)
    let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    #expect(pixels == expectedPixels, "\(file)")
    let data = try #require(image.pngData())
    try data.write(to: directory.appendingPathComponent(file))
  }
}
