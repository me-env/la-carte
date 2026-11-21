#!/usr/bin/env bash
# Downloads the Vyst App Store screenshots used as design reference into docs/design/reference/
# (gitignored: third-party images, not ours to commit).
set -euo pipefail
OUT="$(cd "$(dirname "$0")/.." && pwd)/docs/design/reference"
mkdir -p "$OUT"
LOOKUP="$(curl -s 'https://itunes.apple.com/lookup?id=6760647645&country=us')"
names=(01-editor-dark 02-editor-light 03-detail-light 04-list-dark 05-theme-forest)
i=0
for url in $(echo "$LOOKUP" | python3 -I -c "import json,sys; print('\n'.join(u.replace('320x480bb','600x1300bb') for u in json.load(sys.stdin)['results'][0]['screenshotUrls']))"); do
  curl -s "$url" -o "$OUT/${names[$i]:-extra-$i}.jpg"; i=$((i+1))
done
curl -s "$(echo "$LOOKUP" | python3 -I -c "import json,sys; print(json.load(sys.stdin)['results'][0]['artworkUrl512'])")" -o "$OUT/app-icon.jpg"
ls "$OUT"
