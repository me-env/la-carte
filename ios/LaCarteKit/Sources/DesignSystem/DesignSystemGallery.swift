import SwiftUI

/// Every token and component on one screen. UI tests screenshot it (light, dark, large text) so the
/// design system is reviewed in isolation from features. Launch with `LA_CARTE_SCREEN=design-system`.
public struct DesignSystemGallery: View {
  public init() {}

  public var body: some View {
    ScrollView {
      DesignSystemGalleryContent()
    }
    .background(Theme.background)
  }
}

/// The gallery without its scroll view, so `ImageRenderer` can draw it (`RenderTests`).
struct DesignSystemGalleryContent: View {
  @State private var lastTapped = "none"

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
      Text("Design system")
        .font(.screenTitle)
        .foregroundStyle(Theme.ink)

      section("Logo") {
        logoSection
      }

      // Forgot, Hard, touch-down, Got it, Easy: scattered to ordered (the study size, scaled down).
      section("Rating dial") {
        HStack(spacing: Theme.Spacing.xs) {
          ForEach([0, 0.25, 0.5, 0.76, 1], id: \.self) { value in
            RatingDial(value: value, radius: 108)
              .scaleEffect(0.25)
              .frame(width: 64, height: 64)
          }
        }
        .accessibilityIdentifier("gallery.ratingDial")
      }

      section("Colors") {
        swatchRow
      }

      // Only `\.appTheme`, not `.appTheme(_:)`, so the window's color scheme stays as it is.
      section("Forest") {
        swatchRow
          .padding(Theme.Spacing.s)
          .background(Theme.background, in: .rect(cornerRadius: Theme.Radius.row))
          .padding(.horizontal, -Theme.Spacing.s)
          .environment(\.appTheme, .forest)
      }

      section("Type") {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
          Text("serendipity").font(.cardFace)
          Text("What does ephemeral mean?").font(.cardFaceMedium)
          Text("Which treaty, signed in 1648, ended the Thirty Years' War?").font(.cardFaceSmall)
          Text("the sea").font(.cardAnswer).foregroundStyle(Theme.secondaryInk)
          Text("Cards").font(.screenTitle)
          Text("finding something good without looking for it").font(.body)
          Text("Jan 1, 2026 · new").font(.meta).foregroundStyle(Theme.secondaryInk)
        }
        .foregroundStyle(Theme.ink)
      }

      section("Buttons") {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
          HStack(spacing: Theme.Spacing.m) {
            ForEach(["list.bullet", "plus", "xmark", "arrow.uturn.backward"], id: \.self) { icon in
              CircleIconButton(icon, accessibilityLabel: LocalizedStringKey(icon)) {
                lastTapped = icon
              }
              .accessibilityIdentifier("gallery.button.\(icon)")
            }
          }
          Text("Last tapped: \(lastTapped)")
            .font(.meta)
            .foregroundStyle(Theme.secondaryInk)
            .accessibilityIdentifier("gallery.lastTapped")
        }
      }
    }
    .padding(Theme.Spacing.l)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The mark on each theme, at app-icon (29), button (44) and hero (64) sizes, then the draw-in phases and the
  /// live launch/loading marks. Each tile sets its own scheme + theme, so all three show whatever the app runs in.
  private var logoSection: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: Theme.Spacing.s) { logoThemes }
        VStack(spacing: Theme.Spacing.s) { logoThemes }
      }
      HStack(spacing: Theme.Spacing.m) {
        ForEach([0.25, 0.5, 0.75, 1], id: \.self) { progress in
          VStack(spacing: Theme.Spacing.xs) {
            LaCarteLogo(progress: progress).frame(width: 56, height: 56)
            Text(progress.formatted(.percent)).font(.meta).foregroundStyle(Theme.secondaryInk)
          }
        }
      }
      .accessibilityIdentifier("gallery.logo.phases")
      HStack(spacing: Theme.Spacing.l) {
        VStack(spacing: Theme.Spacing.xs) {
          LaCarteLaunchMark().frame(width: 56, height: 56)
          Text("launch").font(.meta).foregroundStyle(Theme.secondaryInk)
        }
        VStack(spacing: Theme.Spacing.xs) {
          LaCarteLoadingMark().frame(width: 56, height: 56)
          Text("loading").font(.meta).foregroundStyle(Theme.secondaryInk)
        }
      }
      .accessibilityIdentifier("gallery.logo.live")
    }
  }

  @ViewBuilder private var logoThemes: some View {
    logoTile("light", theme: .light, scheme: .light)
    logoTile("dark", theme: .dark, scheme: .dark)
    logoTile("forest", theme: .forest, scheme: .dark)
  }

  private func logoTile(_ name: String, theme: AppTheme, scheme: ColorScheme) -> some View {
    VStack(spacing: Theme.Spacing.xs) {
      HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
        LaCarteLogo().frame(width: 29, height: 29)
        LaCarteLogo().frame(width: 44, height: 44)
        LaCarteLogo().frame(width: 64, height: 64)
      }
      .padding(Theme.Spacing.s)
      .frame(maxWidth: .infinity)
      .background(Theme.background, in: .rect(cornerRadius: Theme.Radius.row))
      .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row).strokeBorder(Theme.hairline))
      .environment(\.appTheme, theme)
      .environment(\.colorScheme, scheme)
      Text(name).font(.meta).foregroundStyle(Theme.secondaryInk)
    }
    .accessibilityIdentifier("gallery.logo.\(name)")
  }

  private var swatchRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Theme.Spacing.s) { swatches }
      VStack(spacing: Theme.Spacing.s) { swatches }
    }
  }

  @ViewBuilder private var swatches: some View {
    swatch("background", Theme.background)
    swatch("surface", Theme.surface)
    swatch("ink", Theme.ink)
    swatch("secondary", Theme.secondaryInk)
    swatch("hairline", Theme.hairline)
    swatch("accent", Theme.accent)
  }

  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
      Text(title.uppercased())
        .font(.meta)
        .foregroundStyle(Theme.secondaryInk)
      content()
    }
  }

  private func swatch(_ name: String, _ color: ThemeColor) -> some View {
    VStack(spacing: Theme.Spacing.xs) {
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(color)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row).strokeBorder(Theme.hairline))
        .frame(height: 56)
      Text(name).font(.meta).foregroundStyle(Theme.secondaryInk).fixedSize()
    }
  }
}

#Preview("System") {
  DesignSystemGallery()
}

#Preview("Forest") {
  DesignSystemGallery()
    .appTheme(.forest)
}
