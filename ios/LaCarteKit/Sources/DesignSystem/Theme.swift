import SwiftUI

/// Design tokens. Reference: docs/design-system.md (Vyst-inspired: quiet, warm, one thing on screen).
public enum Theme {
  /// Warm off-white paper / soft charcoal / deep green.
  public static let background = ThemeColor(light: 0xF9FAF5, dark: 0x1A1A1A, forest: 0x0E1913)
  /// Raised elements: buttons, list rows.
  public static let surface = ThemeColor(light: 0xFFFFFF, dark: 0x252525, forest: 0x16241B)
  public static let ink = ThemeColor(light: 0x1C1C1C, dark: 0xF2F2F0, forest: 0xEEF2EC)
  public static let secondaryInk = ThemeColor(light: 0x9D9D9B, dark: 0x8A8A88, forest: 0x83938A)
  public static let hairline = ThemeColor(
    light: .black.opacity(0.08), dark: .white.opacity(0.08), forest: .white.opacity(0.08)
  )
  /// Accent pink (#ED6E8C), in **small amounts** only: the logo's line outside the card, the text
  /// cursor/selection, the widget's streak number. Never backgrounds, large fills, body text or buttons.
  /// Light uses the darker #B8325A so it stays legible on paper (5.5:1 on background, AA for text).
  public static let accent = ThemeColor(light: 0xB8325A, dark: 0xED6E8C, forest: 0xED6E8C)

  public enum Spacing {
    /// A caption tight under its sample (gallery swatches, logo sizes).
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 40
  }

  public enum Radius {
    public static let row: CGFloat = 12
    /// A person's photo on the card face (spec 014d), continuous corners.
    public static let photo: CGFloat = 20
  }

  /// A person's photo (spec 014): circles in the deck row and the editor, a 4:5 portrait on the card face.
  public enum Photo {
    public static let thumbnail: CGFloat = 44
    public static let preview: CGFloat = 88
    /// Width of the card-face photo; `cardCompact` at accessibility text sizes.
    public static let card: CGFloat = 240
    public static let cardCompact: CGFloat = 160
  }

  /// Calm, ease-in-out, nothing bounces. Every use has a Reduce Motion variant (a fade or nothing).
  public enum Motion {
    /// Fades, reveals, row changes.
    public static let standard = Animation.easeInOut(duration: 0.25)
    /// The logo drawing itself in (launch, empty screens).
    public static let logoDrawIn = Animation.easeInOut(duration: 0.9)
    /// One half of the loading mark's loop (write, then erase).
    public static let loadingPulse = Animation.easeInOut(duration: 0.8)
  }
}

/// How the app looks, picked in Settings (spec 004). `system` follows the device.
public enum AppTheme: String, CaseIterable, Sendable {
  case system, light, dark, forest

  /// The defaults key it is stored under (App Group suite), shared by Settings and the widget.
  public static let storageKey = "theme"
}

/// A token that resolves itself from the environment (`\.appTheme` + `colorScheme`), so themes need no globals.
public struct ThemeColor: ShapeStyle {
  let light: Color
  let dark: Color
  let forest: Color

  public func resolve(in environment: EnvironmentValues) -> Color {
    if environment.appTheme == .forest { return forest }
    return environment.colorScheme == .dark ? dark : light
  }
}

extension ThemeColor {
  init(light: UInt32, dark: UInt32, forest: UInt32) {
    self.init(light: Color(hex: light), dark: Color(hex: dark), forest: Color(hex: forest))
  }
}

extension EnvironmentValues {
  @Entry public var appTheme: AppTheme = .system
}

extension View {
  /// Applies the theme: sets `\.appTheme` and the window's interface style (status bar, keyboard, open sheets).
  public func appTheme(_ theme: AppTheme) -> some View {
    environment(\.appTheme, theme)
      .background(WindowStyle(style: theme.interfaceStyle))
  }
}

extension Theme {
  /// `.tint` doesn't reach the navigation bar's search field cursor (iOS 27), so it's set through UIKit.
  /// Forest is dark-styled and shares dark's accent, so light/dark traits are enough. Called by `RootView`.
  @MainActor public static func tintSearchFields() {
    UISearchTextField.appearance().tintColor = UIColor { traits in
      UIColor(traits.userInterfaceStyle == .dark ? accent.dark : accent.light)
    }
  }
}

extension AppTheme {
  fileprivate var interfaceStyle: UIUserInterfaceStyle {
    switch self {
    case .system: .unspecified
    case .light: .light
    case .dark, .forest: .dark
    }
  }
}

/// Sets the window's `overrideUserInterfaceStyle`: unlike `preferredColorScheme(nil)`, going back to
/// `.unspecified` also resets sheets that are already presented.
private struct WindowStyle: UIViewRepresentable {
  let style: UIUserInterfaceStyle

  func makeUIView(context: Context) -> StyleView { StyleView() }

  func updateUIView(_ view: StyleView, context: Context) {
    view.style = style
  }

  final class StyleView: UIView {
    var style = UIUserInterfaceStyle.unspecified {
      didSet { window?.overrideUserInterfaceStyle = style }
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      window?.overrideUserInterfaceStyle = style
    }
  }
}

/// Text styles, not fixed sizes, so every style scales with Dynamic Type (sizes below are the defaults).
extension Font {
  /// The single word / phrase in the middle of the screen. 34pt.
  public static let cardFace = Font.system(.largeTitle, weight: .medium)
  /// A card question of 25–60 characters. 28pt.
  public static let cardFaceMedium = Font.system(.title, weight: .medium)
  /// A long card question (> 60 characters or a line break), the smallest a question gets. 22pt.
  public static let cardFaceSmall = Font.system(.title2, weight: .medium)
  /// A short answer under a question that isn't long, the largest an answer gets. 22pt.
  public static let cardAnswer = Font.system(.title2)
  /// 28pt.
  public static let screenTitle = Font.system(.title, weight: .bold)
  /// 13pt.
  public static let meta = Font.footnote
}

/// Size of a card's text from its length (spec 017): a word stays big, a paragraph is smaller. Character counts,
/// so the size never changes with the width or while editing. (Alignment follows rendered lines, in Study.)
public enum CardText {
  public static let shortLimit = 24
  public static let longLimit = 60

  /// More than `longLimit` characters or a line break, surrounding whitespace not counted.
  public static func isLong(_ text: String) -> Bool {
    let text = trimmed(text)
    return text.count > longLimit || text.contains(where: \.isNewline)
  }

  /// The question depends only on itself: it's shown before the answer, so it must not hint at it.
  public static func promptFont(_ prompt: String) -> Font {
    if isLong(prompt) { return .cardFaceSmall }
    return isShort(prompt) ? .cardFace : .cardFaceMedium
  }

  /// Always a tier below the question: `.body` once the question is at its smallest.
  public static func answerFont(_ answer: String, prompt: String) -> Font {
    isShort(answer) && !isLong(prompt) ? .cardAnswer : .body
  }

  private static func isShort(_ text: String) -> Bool {
    !isLong(text) && trimmed(text).count <= shortLimit
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}
