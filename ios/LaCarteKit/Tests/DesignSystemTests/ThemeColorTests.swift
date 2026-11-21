import SwiftUI
import Testing

@testable import DesignSystem

struct ThemeColorTests {
  @Test(arguments: [
    (AppTheme.system, ColorScheme.light, 0xF9FAF5, 0xFFFFFF, 0x1C1C1C, 0x9D9D9B),
    (.light, .light, 0xF9FAF5, 0xFFFFFF, 0x1C1C1C, 0x9D9D9B),
    (.system, .dark, 0x1A1A1A, 0x252525, 0xF2F2F0, 0x8A8A88),
    (.dark, .dark, 0x1A1A1A, 0x252525, 0xF2F2F0, 0x8A8A88),
    (.forest, .dark, 0x0E1913, 0x16241B, 0xEEF2EC, 0x83938A),
    // Forest ignores the scheme, so a light trait leaking through still shows the forest palette.
    (.forest, .light, 0x0E1913, 0x16241B, 0xEEF2EC, 0x83938A),
  ])
  func paletteResolvesFromThemeAndScheme(
    theme: AppTheme, scheme: ColorScheme, background: Int, surface: Int, ink: Int, secondaryInk: Int
  ) {
    let environment = environment(theme, scheme)
    #expect(hex(Theme.background, environment) == background)
    #expect(hex(Theme.surface, environment) == surface)
    #expect(hex(Theme.ink, environment) == ink)
    #expect(hex(Theme.secondaryInk, environment) == secondaryInk)
  }

  @Test func forestHasAWhiteHairlineAndNoShadowLikeDark() {
    for theme in [AppTheme.dark, .forest] {
      let environment = environment(theme, .dark)
      let hairline = Theme.hairline.resolve(in: environment).resolve(in: environment)
      #expect(hairline.red == 1 && hairline.green == 1 && hairline.blue == 1)
      #expect(abs(hairline.opacity - 0.08) < 0.001)
      #expect(Theme.shadow.resolve(in: environment).resolve(in: environment).opacity == 0)
    }
  }

  /// The accent is the darker pink on light paper and Flourish Pink on dark/forest; on the ink card it's the reverse.
  @Test(arguments: [
    (AppTheme.light, ColorScheme.light, 0xB8325A, 0xED6E8C),
    (.dark, .dark, 0xED6E8C, 0xB8325A),
    (.forest, .dark, 0xED6E8C, 0xB8325A),
  ])
  func accentKeepsContrast(theme: AppTheme, scheme: ColorScheme, accent: Int, onInk: Int) {
    let environment = environment(theme, scheme)
    #expect(hex(Theme.accent, environment) == accent)
    #expect(hex(Theme.accentOnInk, environment) == onInk)
  }

  private func environment(_ theme: AppTheme, _ scheme: ColorScheme) -> EnvironmentValues {
    var environment = EnvironmentValues()
    environment.appTheme = theme
    environment.colorScheme = scheme
    return environment
  }

  private func hex(_ token: ThemeColor, _ environment: EnvironmentValues) -> Int {
    let c = token.resolve(in: environment).resolve(in: environment)
    let channel = { (v: Float) in Int((v * 255).rounded()) }
    return channel(c.red) << 16 | channel(c.green) << 8 | channel(c.blue)
  }
}
