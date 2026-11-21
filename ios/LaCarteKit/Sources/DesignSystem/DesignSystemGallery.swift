import SwiftUI

/// Every token and component on one screen. UI tests screenshot it (light, dark, large text) so the
/// design system is reviewed in isolation from features. Launch with `LA_CARTE_SCREEN=design-system`.
public struct DesignSystemGallery: View {
  @State private var lastTapped = "none"

  public init() {}

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.l) {
        Text("Design system")
          .font(.screenTitle)
          .foregroundStyle(Theme.ink)

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
    .background(Theme.background)
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
    VStack(spacing: 4) {
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
