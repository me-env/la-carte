import SwiftUI
import Testing
import UIKit

@testable import DesignSystem

/// The Google button's bundled assets load (spec 030c): a missing font would silently fall back to SF, a missing
/// "G" would draw nothing, and both break Google's branding guidelines.
@MainActor
struct ContinueWithGoogleButtonTests {
  @Test func googleSansIsBundledAndRegisters() {
    #expect(GoogleBrand.registered)
    #expect(UIFont(name: GoogleBrand.postScriptName, size: 17) != nil)
  }

  @Test func theGMarkHasALightAndADarkVariant() throws {
    let light = try #require(UIImage(named: "GoogleG", in: GoogleBrand.bundle, compatibleWith: UITraitCollection(userInterfaceStyle: .light)))
    let dark = try #require(UIImage(named: "GoogleG", in: GoogleBrand.bundle, compatibleWith: UITraitCollection(userInterfaceStyle: .dark)))
    #expect(light.size == CGSize(width: 20, height: 20))
    #expect(light.pngData() != dark.pngData())
  }

  @Test(arguments: [(AppTheme.light, ColorScheme.light, 0xFFFFFF), (.dark, .dark, 0x131314), (.forest, .dark, 0x131314)])
  func fillFollowsGoogleThemes(theme: AppTheme, scheme: ColorScheme, fill: Int) {
    var environment = EnvironmentValues()
    environment.appTheme = theme
    environment.colorScheme = scheme
    let color = GoogleBrand.fill.resolve(in: environment).resolve(in: environment)
    let hex = Int((color.red * 255).rounded()) << 16 | Int((color.green * 255).rounded()) << 8 | Int((color.blue * 255).rounded())
    #expect(hex == fill)
  }
}
