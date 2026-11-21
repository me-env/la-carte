import XCTest

/// End-to-end UI tests. Owned by the `qa-validator` agent (see docs/testing.md).
///
/// Every test that validates a screen calls `snapshot(_:)`; scripts/ios-ui-test.sh exports those
/// attachments to qa/screenshots/<run>/ for review.
final class LaCarteUITests: XCTestCase {
  static let galleryIcons = ["list.bullet", "plus", "xmark", "arrow.uturn.backward"]

  override func setUp() {
    continueAfterFailure = false
  }

  // Spec 001 Study tests: StudyUITests.swift (they replace spec 000's testHome_*).

  // MARK: - Design-system gallery (spec 000, criteria 4, 5, 6)

  /// 000 #4: gallery renders in both appearances with the 4 circle buttons (44pt).
  @MainActor
  func testDesignSystem_gallery() {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock, screen: "design-system")
      for icon in Self.galleryIcons {
        let button = app.buttons["gallery.button.\(icon)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "missing gallery.button.\(icon)")
        XCTAssertGreaterThanOrEqual(button.frame.width, 44, "\(icon) hit area too narrow: \(button.frame)")
        XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(icon) hit area too short: \(button.frame)")
      }
      XCTAssertTrue(app.staticTexts["gallery.lastTapped"].exists)
      snapshot("design-system", appearance: appearance)
    }
  }

  /// 000 #5: tapping each circle button updates `gallery.lastTapped`.
  @MainActor
  func testDesignSystem_tapEachButton() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock, screen: "design-system")
    let lastTapped = app.staticTexts["gallery.lastTapped"]
    XCTAssertTrue(lastTapped.waitForExistence(timeout: 5))
    for icon in Self.galleryIcons {
      let button = app.buttons["gallery.button.\(icon)"]
      XCTAssertTrue(button.waitForExistence(timeout: 5), "missing gallery.button.\(icon)")
      XCTAssertTrue(button.isHittable, "gallery.button.\(icon) not hittable")
      button.tap()
      waitForLabel(lastTapped, "Last tapped: \(icon)", timeout: 3)
    }
    snapshot("design-system-tapped", appearance: .light)
  }

  /// 000 #5 (hit area): tapping near the edge of the 44pt circle still registers.
  @MainActor
  func testDesignSystem_tapButtonEdge() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock, screen: "design-system")
    let lastTapped = app.staticTexts["gallery.lastTapped"]
    XCTAssertTrue(lastTapped.waitForExistence(timeout: 5))
    for icon in Self.galleryIcons {
      let button = app.buttons["gallery.button.\(icon)"]
      XCTAssertTrue(button.waitForExistence(timeout: 5))
      // ~4pt inside the right edge, vertically centered.
      let dx = max(0.0, (button.frame.width - 4) / button.frame.width)
      button.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
      waitForLabel(lastTapped, "Last tapped: \(icon)", timeout: 3)
    }
  }

  /// 000 #6: gallery at Dynamic Type accessibility XL, both appearances.
  @MainActor
  func testDesignSystem_accessibilityXL() {
    continueAfterFailure = true  // capture both appearances even if scaling fails
    let baseline = launch(api: .mock, screen: "design-system")
    XCTAssertTrue(baseline.staticTexts["gallery.lastTapped"].waitForExistence(timeout: 5))
    let baseHeight = baseline.staticTexts["gallery.lastTapped"].frame.height
    baseline.terminate()

    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock, screen: "design-system", arguments: accessibilityXLArguments)
      XCTAssertTrue(app.staticTexts["gallery.lastTapped"].waitForExistence(timeout: 5)
        || app.buttons["gallery.button.list.bullet"].waitForExistence(timeout: 5))
      snapshot("design-system-xl", appearance: appearance)
      assertTextsReadable(in: app)
      // Scroll to reveal the rest of the gallery, if it scrolls.
      let scroll = app.scrollViews.firstMatch
      if scroll.exists {
        scroll.swipeUp()
        assertTextsReadable(in: app)
        snapshot("design-system-xl-scrolled", appearance: appearance)
      }
      // Dynamic Type must actually apply (checked after the screenshots so they're always captured).
      if app.staticTexts["gallery.lastTapped"].exists {
        XCTAssertGreaterThan(app.staticTexts["gallery.lastTapped"].frame.height, baseHeight * 1.3,
                             "gallery text did not scale with Dynamic Type (height \(baseHeight) at default)")
      }
    }
  }
}
