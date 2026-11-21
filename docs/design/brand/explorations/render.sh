#!/usr/bin/env bash
# Logo explorations for the user to choose from (not shipped). Each variant: logo + app icon, light + dark,
# with the pink accent on the "word" only. PNGs: 1024 icon and 58 px (= 29 pt @2x, the Settings/Spotlight size).
#   a-current  one landscape card, one word, next card tilted behind (what ships today)
#   b-stack    two same-size cards offset like a deck; two text lines (word in pink, answer in grey)
#   c-fan      two portrait cards fanned like playing cards; two text lines (pink word, grey answer)
set -euo pipefail
cd "$(dirname "$0")"

# $1 bg, $2 next card, $3 front card, $4 accent, $5 grey line
a() { cat <<SVG
    <rect x="24" y="20" width="52" height="26" rx="8" fill="$2" transform="rotate(-8 50 33)"/>
    <rect x="14" y="32" width="72" height="50" rx="10" fill="$3"/>
    <rect x="34" y="54" width="32" height="6" rx="3" fill="$4"/>
SVG
}
b() { cat <<SVG
    <rect x="22" y="22" width="66" height="46" rx="9" fill="$2"/>
    <rect x="12" y="32" width="66" height="46" rx="9" fill="$3" stroke="$1" stroke-width="3" paint-order="stroke"/>
    <rect x="22" y="46" width="34" height="6" rx="3" fill="$4"/>
    <rect x="22" y="58" width="22" height="6" rx="3" fill="$5"/>
SVG
}
c() { cat <<SVG
    <g transform="translate(-3 0)">
      <rect x="27" y="20" width="46" height="64" rx="8" fill="$2" transform="rotate(12 50 84)"/>
      <g transform="rotate(-6 50 84)">
        <rect x="27" y="20" width="46" height="64" rx="8" fill="$3" stroke="$1" stroke-width="3" paint-order="stroke"/>
        <rect x="35" y="42" width="26" height="6" rx="3" fill="$4"/>
        <rect x="35" y="54" width="16" height="6" rx="3" fill="$5"/>
      </g>
    </g>
SVG
}

write() { # variant theme bg next front accent grey
  local v=$1 t=$2
  { echo '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">'
    echo '  <g>'; "${v:0:1}" "$3" "$4" "$5" "$6" "$7"; echo '  </g>'; echo '</svg>'; } > "$v/logo-$t.svg"
  { echo '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
    echo "  <rect width=\"1024\" height=\"1024\" fill=\"$3\"/>"
    echo '  <g transform="translate(132 132) scale(7.6)">'; "${v:0:1}" "$3" "$4" "$5" "$6" "$7"; echo '  </g>'
    echo '</svg>'; } > "$v/icon-$t.svg"
  rsvg-convert -w 1024 -h 1024 "$v/icon-$t.svg" -o "$v/icon-$t-1024.png"
  rsvg-convert -w 58 -h 58 "$v/icon-$t.svg" -o "$v/icon-$t-58.png"
}

for v in a-current b-stack c-fan; do
  mkdir -p "$v"
  write "$v" light '#F9FAF5' '#9D9D9B' '#1C1C1C' '#ED6E8C' '#9D9D9B'
  write "$v" dark '#1A1A1A' '#8A8A88' '#F2F2F0' '#B8325A' '#8A8A88'
done
echo "✅ explorations rendered"
