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
  /// Soft lift under circle buttons in light mode; the dark themes use `hairline` instead.
  public static let shadow = ThemeColor(light: .black.opacity(0.06), dark: .clear, forest: .clear)

  public enum Spacing {
    public static let s: CGFloat = 8
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 40
  }

  public enum Radius {
    public static let row: CGFloat = 12
  }
}

/// How the app looks, picked in Settings (spec 004). `system` follows the device.
public enum AppTheme: String, CaseIterable, Sendable {
  case system, light, dark, forest
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
  /// 28pt.
  public static let screenTitle = Font.system(.title, weight: .bold)
  /// 13pt.
  public static let meta = Font.footnote
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
