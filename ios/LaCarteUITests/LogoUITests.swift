import XCTest

/// The la-carte mark (logo 131: a card crossed by the forgetting curve, pink outside the card) as the device draws
/// it: the gallery's logo tiles in light/dark/forest, the launch mark drawing in once, the loading mark looping.
/// Geometry and progress maths are unit-tested in LaCarteKit (`LaCarteLogoTests`); here only what needs the screen.
final class LogoUITests: XCTestCase {
  /// `Theme.accent` per scheme (light #B8325A, dark/forest #ED6E8C).
  static let accentLight = RGB(184, 50, 90)
  static let accentDark = RGB(237, 110, 140)

  override func setUp() {
    continueAfterFailure = false
  }

  /// Gallery logo section in the device's light and dark scheme: tiles (light/dark/forest at 29/44/64), draw-in
  /// phases, settled launch + loading marks. The finished launch mark shows both the ink card and the pink line.
  @MainActor
  func testLogo_gallery() {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock, screen: "design-system")
      let live = el(app, "gallery.logo.live")
      XCTAssertTrue(live.waitFor(timeout: 10), "gallery.logo.live missing")
      XCTAssertTrue(el(app, "gallery.logo.phases").exists, "gallery.logo.phases missing")
      settle(2.5)
      let palette = Palette.of(appearance)
      let accent = appearance == .dark ? Self.accentDark : Self.accentLight
      let probe = ColorProbe(screenOf: app)
      let mark = launchMarkRect(live)
      assertMark(probe, mark, ink: palette.ink, accent: accent, "launch mark (\(appearance))")
      snapshot("logo-gallery", appearance: appearance)
      app.terminate()
    }
  }

  /// Gallery with `-theme forest`: the tiles keep their own themes, the live marks take forest (ink #EEF2EC,
  /// accent #ED6E8C on #0E1913).
  @MainActor
  func testLogo_galleryForest() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock, screen: "design-system", theme: "forest")
    let live = el(app, "gallery.logo.live")
    XCTAssertTrue(live.waitFor(timeout: 10), "gallery.logo.live missing")
    settle(2.5)
    assertMark(ColorProbe(screenOf: app), launchMarkRect(live), ink: Palette.forest.ink, accent: Self.accentDark,
               "launch mark (forest)")
    snapshot("logo-gallery-forest", appearance: .light)
  }

  /// `LaCarteLaunchMark` draws in once (≈0.9 s) and then stays still; `LaCarteLoadingMark` keeps drawing and
  /// erasing the curve over the card (0.8 s each way) and the card never disappears. Frames are attached as
  /// `logo-launch-t<ms>` / `logo-loading-t<ms>`; the draw-in itself is timed from the run's recording.
  @MainActor
  func testLogo_launchAndLoadingMarks() {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock, screen: "design-system")
      let live = el(app, "gallery.logo.live")
      XCTAssertTrue(live.waitFor(timeout: 10), "gallery.logo.live missing")
      let launchRect = launchMarkRect(live), loadingRect = loadingMarkRect(live)
      XCTAssertGreaterThan(loadingRect.minX, launchRect.maxX, "loading mark not right of the launch mark")
      let suffix = appearance == .dark ? "dark" : "light"
      let palette = Palette.of(appearance)

      // Early frames (whatever part of the draw-in is still running when the element is found).
      let start = Date()
      var frames: [(ms: Int, image: CGImage)] = []
      while Date().timeIntervalSince(start) < 8 {  // ≈5 loading loops (1.6 s each)
        let shot = XCUIScreen.main.screenshot()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        frames.append((ms, shot.image.cgImage!))
        if frames.count % 5 == 1 { attach(shot, "logo-frames-t\(String(format: "%04d", ms))-\(suffix)") }
      }
      XCTAssertGreaterThanOrEqual(frames.count, 5, "too few frames sampled")

      // Launch mark: still from 8 s on (draws in once, no loop).
      settle(1)
      let settledA = XCUIScreen.main.screenshot().image.cgImage!
      settle(2)
      let settledB = XCUIScreen.main.screenshot().image.cgImage!
      XCTAssertEqual(changedPoints(settledA, settledB, in: launchRect), 0,
                     "launch mark still moving after draw-in (\(suffix))")

      // Loading mark: changes across the sampled frames (curve drawn/erased) while the ink card stays.
      let loadingChanges = frames.dropFirst().map { changedPoints(frames[0].image, $0.image, in: loadingRect) }
      XCTAssertGreaterThan(loadingChanges.max() ?? 0, 20, "loading mark doesn't animate (\(suffix)): \(loadingChanges)")
      for frame in frames {
        // The card itself is never pink (the line's outside part is the only pink): lower card, below the curve.
        let r = loadingRect
        let lowerCard = CGRect(x: r.minX + r.width * 0.45, y: r.minY + r.height * 0.7, width: r.width * 0.45,
                               height: r.height * 0.25)
        let pink = ColorProbe(at3x: frame.image).colors(in: lowerCard, step: 0.5)
          .filter { $0.isClose(to: appearance == .dark ? Self.accentDark : Self.accentLight, tolerance: 40) }.count
        if pink >= 10 {
          let attachment = XCTAttachment(image: UIImage(cgImage: frame.image))
          attachment.name = "logo-loading-pinkcard-t\(frame.ms)-\(suffix)"
          attachment.lifetime = .keepAlways
          add(attachment)
        }
        XCTAssertLessThan(pink, 10, "loading mark card filled pink at t=\(frame.ms) ms (\(suffix))")
        let ink = ColorProbe(at3x: frame.image).colors(in: loadingRect, step: 0.5)
          .filter { $0.isClose(to: palette.ink, tolerance: 40) }.count
        XCTAssertGreaterThan(ink, 50, "loading mark lost its card at t=\(frame.ms) ms (\(suffix))")
      }
      app.terminate()
    }
  }

  // MARK: - Helpers

  /// The launch mark's frame. `gallery.logo.live` sits on an HStack without its own accessibility element, so the
  /// identifier lands on each mark: the launch mark is the one labelled "la carte", the loading mark "Loading".
  private func launchMarkRect(_ live: XCUIElement) -> CGRect { liveMark(live, "la carte").frame }

  private func loadingMarkRect(_ live: XCUIElement) -> CGRect { liveMark(live, "Loading").frame }

  private func liveMark(_ live: XCUIElement, _ label: String) -> XCUIElement {
    let mark = XCUIApplication().descendants(matching: .any).matching(identifier: "gallery.logo.live")
      .matching(NSPredicate(format: "label == %@", label)).firstMatch
    XCTAssertTrue(mark.exists, "no gallery.logo.live element labelled \(label)")
    return mark
  }

  private func assertMark(_ probe: ColorProbe, _ rect: CGRect, ink: RGB, accent: RGB, _ context: String,
                          file: StaticString = #filePath, line: UInt = #line) {
    let colors = probe.colors(in: rect, step: 0.5)
    let inkCount = colors.filter { $0.isClose(to: ink, tolerance: 40) }.count
    let accentCount = colors.filter { $0.isClose(to: accent, tolerance: 40) }.count
    XCTAssertGreaterThan(inkCount, 200, "\(context): no ink card (\(inkCount) samples)", file: file, line: line)
    XCTAssertGreaterThan(accentCount, 30, "\(context): no pink line (\(accentCount) samples)", file: file, line: line)
  }

  private func settle(_ seconds: TimeInterval) {
    _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
  }

  private func attach(_ shot: XCUIScreenshot, _ name: String) {
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
