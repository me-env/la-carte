import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DesignSystem

/// Renders the logo and the design-system gallery to PNGs for design reviews (`scripts/design-review.py`).
/// The gallery renders `DesignSystemGalleryContent` (no ScrollView, which `ImageRenderer` draws empty).
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
  @Test(arguments: [0.0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9, 1.0])
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

  /// 390 pt wide (iPhone 17 Pro) at scale 3; the height is the content's.
  @Test func gallery() throws {
    for (name, theme, scheme) in Self.themes {
      let view = DesignSystemGalleryContent()
        .frame(width: 390)
        .background(Theme.background)
        .environment(\.appTheme, theme)
        .environment(\.colorScheme, scheme)
      try write(view, scale: 3, to: "gallery-\(name).png", expectedPixels: nil)
    }
  }

  /// The positive release rewards frame by frame (spec 019 §6): `dial-release-<settle|burst>-<ms>-<theme>.png`, the
  /// dial at the study size (radius 108) on a 300 pt square, Got it released at 0.76 and Easy at 1.0.
  @Test func dialRelease() throws {
    for (release, value) in [(RatingDial.Release.settle, 0.76), (.burst, 1.0)] {
      for ms in stride(from: 0, through: 600, by: 50) {
        for (name, theme, scheme) in Self.themes where name != "forest" {
          var dial = RatingDial(value: value, radius: 108, release: release)
          dial.fixedTime = Double(ms) / 1000
          let view = dial
            .frame(width: 300, height: 300)
            .background(Theme.background)
            .environment(\.appTheme, theme)
            .environment(\.colorScheme, scheme)
          let kind = release == .settle ? "settle" : "burst"
          try write(view, scale: 3, to: "dial-release-\(kind)-\(String(format: "%03d", ms))-\(name).png", expectedPixels: nil)
        }
      }
    }
  }

  /// The held dial across the drag (spec 019 §3): `dial-held-<value × 1000>-<theme>.png`, the five grades and the
  /// ramps between them, at the study size on a 300 pt square.
  @Test func dialHeld() throws {
    for value in [0, 0.125, 0.15, 0.17, 0.25, 0.5, 0.62, 0.635, 0.76, 0.83, 0.85, 0.875, 1] {
      for (name, theme, scheme) in Self.themes where name != "forest" {
        let view = RatingDial(value: value, radius: 108)
          .frame(width: 300, height: 300)
          .background(Theme.background)
          .environment(\.appTheme, theme)
          .environment(\.colorScheme, scheme)
        try write(view, scale: 3, to: String(format: "dial-held-%04d-%@.png", Int((value * 1000).rounded()), name), expectedPixels: nil)
      }
    }
  }

  private func write(_ view: some View, scale: CGFloat, to file: String, expectedPixels: CGSize?) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    let image = try #require(renderer.uiImage)
    let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    if let expectedPixels { #expect(pixels == expectedPixels, "\(file)") }
    let data = try #require(image.pngData())
    try data.write(to: directory.appendingPathComponent(file))
  }
}
