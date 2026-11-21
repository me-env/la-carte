#!/usr/bin/env bash
# Writes the la-carte logo and app icon SVGs, then renders PNGs with rsvg-convert (brew install librsvg).
# Geometry = `LogoGeometry` in ios/LaCarteKit/Sources/DesignSystem/LaCarteLogo.swift (100×100 box). Keep in sync.
# Colors = tokens in Theme.swift. Re-run after any change: docs/design/brand/render.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p png app-icon

# Two portrait cards (46×64, radius 8) fanned about (47, 81): the next card at +12°, the front card at −6°.
# The next card has a transparent 2-unit gap around the front card (mask). On the front card: the word line
# (accent) and the answer line (secondaryInk). "hole" cuts both lines out instead (mono, tinted icon).
# SVG corners are circular; the app uses continuous corners, invisible at these radii.
CARD='x="24" y="17" width="46" height="64" rx="8"'
FRONT='rotate(-6 47 81)'
mark() { # $1 next card, $2 front card, $3 word ("hole" = cut out), $4 answer, $5 group attrs
  local lines front
  if [ "$3" = hole ]; then
    front="<path fill=\"$2\" fill-rule=\"evenodd\" transform=\"$FRONT\" d=\"M32 17H62A8 8 0 0 1 70 25V73A8 8 0 0 1 62 81H32A8 8 0 0 1 24 73V25A8 8 0 0 1 32 17Z M35 39H55A3 3 0 0 1 55 45H35A3 3 0 0 1 35 39Z M35 51H45A3 3 0 0 1 45 57H35A3 3 0 0 1 35 51Z\"/>"
    lines=''
  else
    front="<rect $CARD fill=\"$2\" transform=\"$FRONT\"/>"
    lines="<g transform=\"$FRONT\"><rect x=\"32\" y=\"39\" width=\"26\" height=\"6\" rx=\"3\" fill=\"$3\"/><rect x=\"32\" y=\"51\" width=\"16\" height=\"6\" rx=\"3\" fill=\"$4\"/></g>"
  fi
  cat <<SVG
  <defs>
    <mask id="gap" maskUnits="userSpaceOnUse" x="0" y="0" width="100" height="100">
      <rect width="100" height="100" fill="white"/>
      <rect $CARD fill="black" stroke="black" stroke-width="4" stroke-linejoin="round" transform="$FRONT"/>
    </mask>
  </defs>
  <g $5>
    <g mask="url(#gap)"><rect $CARD fill="$1" transform="rotate(12 47 81)"/></g>
    $front
    $lines
  </g>
SVG
}

# Accent on the ink card (Theme.accentOnInk): Flourish Pink on the dark card, the darker pink on light cards.
PINK='#ED6E8C'; DEEP_PINK='#B8325A'

logo() { # name next front word answer
  { echo '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">'
    mark "$2" "$3" "$4" "$5" ''
    echo '</svg>'; } > "logo-$1.svg"
}
logo light '#9D9D9B' '#1C1C1C' "$PINK" '#9D9D9B'
logo dark '#8A8A88' '#F2F2F0' "$DEEP_PINK" '#8A8A88'
logo forest '#83938A' '#EEF2EC' "$DEEP_PINK" '#83938A'
# One color, for embossing/watermarks: the next card is the same color at 45%, the lines are cut out.
{ echo '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">'
  mark 'currentColor" fill-opacity="0.45' 'currentColor' hole '' ''
  echo '</svg>'; } > logo-mono.svg

icon() { # name background next front word answer
  { echo '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
    echo "  <rect width=\"1024\" height=\"1024\" fill=\"$2\"/>"
    # The 100-box at 7.6×, centered: the mark is ~500 pt wide (49% of the icon), inside Apple's safe zone.
    echo '  <g transform="translate(132 132) scale(7.6)">'
    mark "$3" "$4" "$5" "$6" ''
    echo '  </g>'
    echo '</svg>'; } > "app-icon/app-icon-$1.svg"
}
icon light '#F9FAF5' '#9D9D9B' '#1C1C1C' "$PINK" '#9D9D9B'
icon dark '#1A1A1A' '#8A8A88' '#F2F2F0' "$DEEP_PINK" '#8A8A88'
# Tinted: grayscale on black, no accent (iOS applies the user's tint by luminance); the lines are cut out.
icon tinted '#000000' '#7A7A7A' '#FFFFFF' hole ''

for theme in light dark forest; do
  for size in 64 256 1024; do
    rsvg-convert -w "$size" -h "$size" "logo-$theme.svg" -o "png/logo-$theme-$size.png"
  done
done
for variant in light dark tinted; do
  rsvg-convert -w 1024 -h 1024 "app-icon/app-icon-$variant.svg" -o "app-icon/app-icon-$variant.png"
  rsvg-convert -w 58 -h 58 "app-icon/app-icon-$variant.svg" -o "app-icon/app-icon-$variant-58.png"
done
ICONSET=../../../ios/LaCarte/Assets.xcassets/AppIcon.appiconset
if [ -d "$ICONSET" ]; then
  for variant in light dark tinted; do cp "app-icon/app-icon-$variant.png" "$ICONSET/"; done
fi
echo "✅ brand assets rendered"
