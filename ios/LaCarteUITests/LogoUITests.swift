import XCTest

/// The la-carte mark (logo 131: a card crossed by the forgetting curve, pink outside the card) as the device draws
/// it: the gallery's logo tiles in light/dark/forest, the launch mark (`LaCarteLaunchMark`, shown above Study's
/// "All caught up", never at app launch) drawing in once with its card tilt, the loading mark looping.
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

  // MARK: - Study "All caught up" (study.logo)

  /// The launch mark sits centred above "All caught up" and draws in once: the frames change (line growth + tilt),
  /// then the mark stays still and shows the ink card and the pink line. The line never loses a piece it has drawn
  /// (pink count per frame never falls far below its running maximum). Frames: `study-logo-t<ms>-<scheme>`.
  @MainActor
  func testStudy_caughtUpLogoDrawIn() {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let suffix = appearance == .dark ? "dark" : "light"
      let app = launch(api: .mock)
      for index in 0..<3 {
        waitForLabel(el(app, "study.front"), StudyUITests.fixtures[index].front)
        el(app, "study.reveal").tap()
        let rate = el(app, "study.rate.good")
        XCTAssertTrue(rate.waitFor(timeout: 5), "study.rate.good missing")
        rate.tap()
      }
      let logo = el(app, "study.logo")
      XCTAssertTrue(logo.waitFor(timeout: 10), "study.logo missing on All caught up")
      let start = Date()
      var frames: [(ms: Int, image: CGImage)] = []
      while Date().timeIntervalSince(start) < 2 {
        let shot = XCUIScreen.main.screenshot()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        frames.append((ms, shot.image.cgImage!))
        attach(shot, "study-logo-t\(String(format: "%04d", ms))-\(suffix)")
      }
      waitForLabel(el(app, "study.message"), "All caught up")
      let rect = logo.frame
      let message = el(app, "study.message").frame
      let window = app.windows.firstMatch.frame
      XCTAssertEqual(rect.width, 64, accuracy: 1, "study.logo not 64 pt: \(rect)")
      XCTAssertEqual(rect.midX, window.midX, accuracy: 1, "study.logo not centred")
      XCTAssertLessThanOrEqual(rect.maxY, message.minY, "study.logo not above study.message")

      settle(1)
      let settledA = XCUIScreen.main.screenshot().image.cgImage!
      settle(1.5)
      let settledB = XCUIScreen.main.screenshot().image.cgImage!
      XCTAssertEqual(changedPoints(settledA, settledB, in: rect), 0, "study.logo still moving after draw-in (\(suffix))")
      let changes = frames.map { changedPoints($0.image, settledB, in: rect) }
      XCTAssertGreaterThan(changes.first ?? 0, 20, "study.logo didn't animate (\(suffix)): \(changes)")

      let accent = appearance == .dark ? Self.accentDark : Self.accentLight
      let pinks = frames.map { ColorProbe(at3x: $0.image).colors(in: rect, step: 0.5)
        .filter { $0.isClose(to: accent, tolerance: 40) }.count }
      XCTContext.runActivity(named: "pink samples per frame (\(suffix)): \(zip(frames.map(\.ms), pinks).map { "\($0)ms:\($1)" })") { _ in }
      var peak = 0
      for (frame, pink) in zip(frames, pinks) {
        XCTAssertGreaterThanOrEqual(Double(pink), Double(peak) * 0.7 - 5,
                                    "line lost a drawn piece at t=\(frame.ms) ms (\(suffix)): \(pinks)")
        peak = max(peak, pink)
      }
      assertMark(ColorProbe(at3x: settledB), rect, ink: Palette.of(appearance).ink, accent: accent,
                 "study.logo settled (\(suffix))")
      snapshot("study-caught-up-logo", appearance: appearance)
      app.terminate()
    }
  }

  /// Nothing at launch shows the logo or delays the first card: with cards due, `study.front` is there right after
  /// launch and `study.logo` never appears while it loads.
  @MainActor
  func testStudy_launchShowsFirstCardNoLogo() {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock)
      let start = Date()
      var sawLogo = false
      let front = el(app, "study.front")
      // `study.front` first: once it's there, the logo is checked below; each query costs ≈ 0.5–1 s on CI.
      let shown = poll(timeout: 5) {
        if front.exists { return true }
        if el(app, "study.logo").exists { sawLogo = true }
        return false
      }
      let elapsed = Date().timeIntervalSince(start)
      snapshot("study-launch-first-card", appearance: appearance)
      XCTContext.runActivity(named: "study.front after \(String(format: "%.2f", elapsed)) s (\(appearance))") { _ in }
      XCTAssertTrue(shown, "study.front missing after launch")
      // `elapsed` is mostly accessibility-query time: CI runners (no GPU, `CI` set by scripts/ios-ui-test.sh) took
      // 1.52–1.92 s for what takes < 0.5 s locally. A real delay (a launch logo, a blocking load) costs seconds more.
      let limit = ProcessInfo.processInfo.environment["CI"]?.isEmpty == false ? 2.5 : 1.5
      XCTAssertLessThan(elapsed, limit, "first card took \(elapsed) s after launch")
      XCTAssertFalse(sawLogo, "study.logo shown at launch")
      XCTAssertFalse(el(app, "study.logo").exists, "study.logo shown with the first card")
      app.terminate()
    }
  }

  /// Auto-refresh doesn't replay the draw-in: caught up (next card in 1 h), mark settled → foreground reload and the
  /// 30 s timer reload both leave the mark pixel-identical.
  @MainActor
  func testStudy_caughtUpLogoNoReplayOnRefresh() throws {
    XCUIDevice.shared.appearance = .light
    let deck = StubDeck([.init(id: "aaaaaaaa-0000-0000-0000-000000000001", front: "canine", back: "dog",
                               due: Date().addingTimeInterval(3600), createdAt: Date())])
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    defer { server.stop() }
    let app = launch(api: .live(server.url))
    waitForLabel(el(app, "study.message"), "All caught up")
    let logo = el(app, "study.logo")
    XCTAssertTrue(logo.waitFor(timeout: 5), "study.logo missing")
    settle(2.5)
    let rect = logo.frame
    let reference = XCUIScreen.main.screenshot().image.cgImage!
    snapshot("study-caught-up-logo-before-refresh", appearance: .light)

    func assertStillDuringReload(_ what: String, within timeout: TimeInterval, trigger: () -> Void) {
      let before = server.requests.count
      trigger()
      XCTAssertTrue(poll(timeout: timeout) { server.requests.count > before }, "no reload after \(what)")
      // The system's app-open zoom moves the whole window for ~0.4 s: wait until the message is back in place
      // (a replayed draw-in lasts 1 s, so it would still be running when sampling starts).
      let message = el(app, "study.message").frame
      XCTAssertTrue(poll(timeout: 3) {
        changedPoints(reference, XCUIScreen.main.screenshot().image.cgImage!, in: message) == 0
      }, "screen not back in place after \(what)")
      let start = Date()
      var worst = 0
      while Date().timeIntervalSince(start) < 2 {
        worst = max(worst, changedPoints(reference, XCUIScreen.main.screenshot().image.cgImage!, in: rect))
      }
      XCTAssertTrue(logo.exists, "study.logo gone after \(what)")
      XCTAssertEqual(worst, 0, "study.logo changed after \(what) (\(worst) points): draw-in replayed?")
    }
    assertStillDuringReload("foreground", within: 5) { backgroundAndReactivate(app) }
    snapshot("study-caught-up-logo-after-foreground", appearance: .light)
    assertStillDuringReload("30 s auto-refresh", within: 35) {}
    snapshot("study-caught-up-logo-after-autorefresh", appearance: .light)
  }

  // Reduce Motion (static, finished mark) isn't covered here: XCUITest can't turn the setting on (launch arguments
  // `-ReduceMotionEnabled` / `-UIAccessibilityReduceMotionEnabled` don't reach SwiftUI's environment, QA 2026-11-23).
  // It's checked by `ScreenColorTests/caughtUpReduceMotion` in LaCarteKit.

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
