# App demo cut (Video A, frames + crossfades)

Built without screen recording (no `simctl io`, no privacy prompt): an XCUITest drives a scripted demo and
saves one screenshot per shot, then `marketing/build-demo.py` composes 1920×1080 frames (brand background,
rounded phone with a hairline edge, SF Pro caption bottom-centre, status bar painted over) and joins them with
0.4 s crossfades. About 43 s, no audio, H.264, under 1 MB. It supersedes Video A in `shot-list.md` (which
predates the two-button ratings, inline edit, notes, report and ask features).

## Reproduce

```bash
LACARTE_AGENT=marketing UI_WORKERS=1 scripts/ios-ui-test.sh marketing \
  -only-testing:LaCarteUITests/MarketingUITests          # ~2 min → qa/screenshots/marketing/
uv run marketing/build-demo.py                            # → $LA_CARTE_MARKETING_OUT (default build/marketing/)
```

Outputs: `app-demo.mp4` and `frames/NN.png` (not committed); the README images in `marketing/readme/` (committed:
`study-{light,dark}`, `more-light`, `widget`; `--readme` rebuilds only those). Second argument changes the
output folder when the SSD isn't mounted.

Data: the in-process stub deck in `ios/LaCarteUITests/MarketingUITests.swift` (demo deck words, one made-up
person "Nora Vale, runs the corner bakery", the stub's generated silhouette photo). The stub listens on
127.0.0.1; no Settings screen is captured, so no URL or token is ever on screen.

## Shots

| # | s | Source frame | Caption |
|---|---|---|---|
| 0 | 3.0 | Title card: "la carte" + "One flashcard deck. Spaced repetition." (text only, no logo) | |
| 1 | 3.0 | `v01-front`: **petrichor**, "8 to review" | One deck. One card at a time |
| 2 | 3.0 | `v02-reveal`: answer + Forgot / Got it | Tap to see the answer |
| 3 | 2.2 | `v03-ring-forgot`: drag ring held left (scattered dots) | Forgot or got it: tap, or drag |
| 4 | 2.2 | `v03-ring-easy`: ring held right (regular circle) | (same) |
| 5 | 3.0 | `v04-edit`: double-tapped answer, "calm" → "calm and peaceful" typed, keyboard up | Double-tap to fix a card in place |
| 6 | 2.0 | `v05-edited`: saved, back at rest | (same) |
| 7 | 2.6 | `v06-person-front`: placeholder photo, "Name and description?" | Remember people: a face |
| 8 | 2.6 | `v07-person-back`: **Nora Vale**, runs the corner bakery | a name, and who they are |
| 9 | 2.6 | `v08-menu`: double-tap menu on "Capital of Australia?" | Double-tap the card for more |
| 10 | 2.6 | `v09-copied`: "Copied" in the counter slot (Ask, copy-only app) | Ask an AI about it |
| 11 | 2.4 | `v10-report-menu`: **Largest planet? / Saturn** (deliberately wrong) + menu | Something wrong? Report it |
| 12 | 2.4 | `v11-reported`: "Reported", next card | Your agent fixes it over MCP |
| 13 | 3.0 | `widget-small-nine-{light,dark}`: widget gallery tiles, "8 to review", streak grid | Your deck on the Home Screen |
| 14 | 3.0 | `theme-{light,dark,forest}`: three phones | Light, dark or forest |
| 15 | 3.2 | End card: "Open source. No account." / "Any agent can add cards over MCP" / `github.com/me-env/la-carte` | |

Captions and durations live in `SHOTS` in `marketing/build-demo.py`; keep this table in sync.

## Known limits

- Stills, not motion: the drag ring and the edit are shown as held states (the `-studySwipePreview` debug
  argument holds the drag). A real-motion take needs `simctl io recordVideo` with the user at the Mac.
- The widget is the in-app debug gallery tile (the same `DeckWidgetView`), not a Home Screen capture; its
  "12-day streak" is the gallery fixture.
- Ask uses the "Copy only" AI app: the simulator has no AI app, and the Claude/ChatGPT links would open a real
  website.
- The status bar is painted over (real clock otherwise); no 9:41 override without `simctl status_bar`.
