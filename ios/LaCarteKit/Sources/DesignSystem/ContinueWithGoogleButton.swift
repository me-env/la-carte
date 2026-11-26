import CoreText
import SwiftUI

/// "Continue with Google" (spec 030c), drawn to Google's "Sign in with Google" branding guidelines
/// (developers.google.com/identity/branding-guidelines, checked 2026-11-26), adapted to la-carte's calm layout:
/// - approved text "Continue with Google", in Google Sans Medium (bundled subset, OFL, `Resources/GoogleSans-OFL.txt`);
/// - the standard-colour "G" from Google's iOS asset bundle (`Brand.xcassets/GoogleG`), unaltered, never tinted;
/// - Google's own themes: Light (white, 1 pt #747775 stroke, #1F1F1F text) in light, Dark (#131314, 1 pt #8E918F
///   stroke, #E3E3E3 text) in dark and forest;
/// - pill shape, iOS padding 16 / 12 / 16 around the G, content centred in a full-width 50 pt button.
/// Google's colours are the one place a third party's literal colours are allowed: they live here, not in `Theme`.
public struct ContinueWithGoogleButton: View {
  private let isLoading: Bool
  private let action: () -> Void

  /// `isLoading` keeps the label and shows a spinner at the trailing edge, so nothing moves while signing in.
  public init(isLoading: Bool = false, action: @escaping () -> Void) {
    self.isLoading = isLoading
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image("GoogleG", bundle: .module)
          .resizable()
          .frame(width: 20, height: 20)
          .accessibilityHidden(true)
        Text("Continue with Google")
          .font(GoogleBrand.font)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 50)
      .overlay(alignment: .trailing) {
        if isLoading {
          ProgressView()
            .tint(GoogleBrand.text)
            .padding(.trailing, 20)
        }
      }
      .contentShape(.capsule)
    }
    .buttonStyle(GoogleButtonStyle())
    .accessibilityLabel("Continue with Google")
    .accessibilityValue(isLoading ? "Signing in" : "")
  }
}

private struct GoogleButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(GoogleBrand.text)
      .background(GoogleBrand.fill, in: .capsule)
      // Google's pressed state: a 12 % overlay of the text colour.
      .overlay(Capsule().fill(GoogleBrand.text).opacity(configuration.isPressed ? 0.12 : 0))
      .overlay(Capsule().inset(by: 0.5).stroke(GoogleBrand.stroke, lineWidth: 1))
      // Google's disabled state: 38 % content, 12 % stroke; the whole pill fades so the G stays unaltered.
      .opacity(isEnabled ? 1 : 0.38)
      .animation(Theme.Motion.standard, value: configuration.isPressed)
  }
}

/// Google's button colours and font. Forest uses the Dark theme (it forces the dark color scheme).
enum GoogleBrand {
  static let fill = ThemeColor(light: 0xFFFFFF, dark: 0x131314, forest: 0x131314)
  static let stroke = ThemeColor(light: 0x747775, dark: 0x8E918F, forest: 0x8E918F)
  static let text = ThemeColor(light: 0x1F1F1F, dark: 0xE3E3E3, forest: 0xE3E3E3)

  /// Google Sans Medium, scaled with Dynamic Type from the body size. Registered once from the module bundle.
  static var font: Font {
    _ = registered
    return .custom(postScriptName, size: 17, relativeTo: .body)
  }

  static let postScriptName = "GoogleSans-TextMedium"
  /// DesignSystem's resource bundle (tests reach it through here).
  static let bundle = Bundle.module

  /// True when the bundled font registered (or already was).
  static let registered: Bool = {
    guard let url = Bundle.module.url(forResource: "GoogleSans-TextMedium", withExtension: "ttf") else { return false }
    var error: Unmanaged<CFError>?
    return CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) || UIFont(name: postScriptName, size: 17) != nil
  }()
}

#Preview {
  VStack(spacing: Theme.Spacing.m) {
    ContinueWithGoogleButton {}
    ContinueWithGoogleButton(isLoading: true) {}
    ContinueWithGoogleButton {}.disabled(true)
  }
  .padding(Theme.Spacing.l)
  .background(Theme.background)
}
