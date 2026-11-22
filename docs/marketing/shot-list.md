# Launch videos: shot lists

> Superseded in part (2026-11-22): the app cut is now built from XCUITest frames, see `app-demo.md`; the agent
> video storyboard is `agent-video.md`. The notes below still hold for a real-motion recording.

Two videos and one README GIF, built with the pipeline in `video-tools.md` (simctl + a demo XCUITest for the app,
VHS + real Claude Code for the terminal, ffmpeg to compose, gifski for the GIF). Deck: `demo-deck.md`, fresh seed
per take.

Style for both: 1920×1080, flat `Theme.background` frame around the phone (light `#F9FAF5`; forest shots may sit
on `#0E1913`), no music, no audio track, captions burned in bottom-centre, sentence case, the app's font (SF Pro),
`Theme.ink` on light / `#EEF2EC` on dark, no boxes, ~2 s each, plain cuts or a 0.3 s fade. One idea per shot.
Status bar: 9:41, full battery, full bars. Text size: default.

## Video A: the app (target 40 s)

Simulator, iPhone 17 Pro, theme Light until shot 8. Launch env points the app at the throwaway API.

| # | Dur | On screen | Caption |
|---|---|---|---|
| 1 | 4 s | Study, front **petrichor** centered, "8 to review" at top. Nothing moves for 1.5 s | One deck. One card at a time. |
| 2 | 3 s | Tap the card: **the smell of rain on dry earth** fades in below, rating row appears | Tap to see the answer. |
| 3 | 4 s | Tap **Good** → **luminous** → tap → **full of light** → tap **Easy** → **Capital of Australia?** | Rate it. It comes back just before you forget. |
| 4 | 4 s | Tap `list.bullet`: the Cards sheet slides up; mixed rows (Due now · new / Due in N days · review) | Your whole deck. |
| 5 | 3 s | Type **lac** in Search: only *laconic* remains. Clear the field | Search it. |
| 6 | 6 s | Tap `plus`: New card. Type **verdant** / **green with plants**, tap `checkmark`: row appears on top | Add a card in seconds. |
| 7 | 6 s | Tap `gearshape` → Appearance: **Light** → **Dark** → **Forest** (1.5 s each). Frame/crop on the Appearance row (see note) | Light, dark, or forest. |
| 8 | 3 s | Close sheets: Study in Forest, **Capital of Australia?** → tap → **Canberra** | (no caption) |
| 9 | 4 s | Home Screen: the small widget, "N to review" + "1-day streak" (forest palette) | Your deck at a glance. |
| 10 | 3 s | End card: flat background, logo (brand kit) + "la carte" + `github.com/me-env/la-carte` | Open source. No account. |

Total ≈ 40 s. Shots 1–8 are one continuous app take driven by the demo XCUITest; 9 is a separate take on the
demo simulator where the widget was placed by hand.

Notes
- Shot 7 shows Settings, which also shows the server URL field and the masked token. In the simulator the URL is
  `http://127.0.0.1:8000` (not private) and the token is fake, but crop or zoom on the Appearance row so the eye
  stays on the themes. Never record a Settings screen holding the real server.
- Shot 9: the widget refreshes when the app goes to the background (spec 007 #21), so press Home *after* the app
  take and the count matches what the app showed.
- Don't use the `-theme forest` launch argument here: it overrides the picker (spec 004 QA note).

## Video B: "add these to my deck" (target 35 s)

Side by side (decided): terminal left (VHS, real Claude Code connected to the throwaway API's
`/mcp`), phone right (simulator take, same API). Fresh seed: the app starts at "8 to review".

| # | Dur | Left: terminal | Right: phone | Caption |
|---|---|---|---|---|
| 1 | 3 s | Claude Code prompt, empty | Study, **petrichor**, "8 to review" | Your agent can use your deck. |
| 2 | 5 s | Types: `Add these to my deck: aurora, zenith, solace` ↵ | (still) | Just ask. |
| 3 | 7 s | Claude calls `add_cards` on la-carte; replies with the 3 cards added | (still) | It adds them over MCP. |
| 4 | 6 s | (still, dimmed or frozen) | Tap `list.bullet`, pull down on the list: **solace**, **zenith**, **aurora** appear on top | Pull to refresh. There they are. |
| 5 | 5 s | (still) | Close the deck, go Home: widget reads **11 to review** | And on your Home Screen. |
| 6 | 3 s | End card (full frame): `claude mcp add --transport http la-carte https://deck.example.com/mcp` + `github.com/me-env/la-carte` | | Any MCP agent. Your own server. |

Total ≈ 29–35 s depending on Claude's real response time. Dead time while the model thinks is **cut**, not sped up
or faked; the MCP call and its result are real (honesty rule from `video-tools.md`).

Notes
- Terminal setup happens inside VHS `Hide`/`Show`: `cd` into a neutral temp dir (no username in the path),
  `claude mcp add --transport http la-carte http://127.0.0.1:8000/mcp --header "Authorization: Bearer demo-token"`,
  and pre-allow `mcp__la-carte__add_cards` so no permission dialog interrupts the take.
- Claude Code's welcome header can show the account email/org and the working directory. Run it under a demo
  config (separate `CLAUDE_CONFIG_DIR`) and have `secrets-guard` check every frame of the terminal render.
- The end card shows a placeholder server (`deck.example.com`), never the real one.
- Widget timing: it reloads when the app is backgrounded, so shot 5 must follow shot 4 (the app was open).

## README GIF (≤ 8 s)

Cut from Video A shots 1–3, light theme, phone only (no frame, no captions, the README line says it all):
**petrichor** → reveal **the smell of rain on dry earth** → Good → **luminous** → reveal **full of light**. ~7 s, 600 px wide, 15 fps,
gifski quality 80, target < 5 MB, loops cleanly (starts and ends on a front at rest).

README pitch above it: *One flashcard deck. Spaced repetition. No account. Any agent can add to it over MCP.*

## What needs a human

- **Go-ahead at the Mac** for every simctl run (`recordVideo`, `status_bar`, `ui appearance` trigger macOS privacy
  prompts).
- **Widget placement, once**: on the dedicated demo simulator, long-press Home → `+` → la carte → small. Then enter
  `http://127.0.0.1:8000` + `demo-token` in Settings off camera (the widget can't read launch env). Needs spec 007
  built first.
- **Claude Code demo login** for Video B (a profile whose header shows nothing personal).
- **Review** of each render and caption wording, then **upload** the MP4 via the GitHub web editor.

## Dependencies on the team (not marketing's to build)

- A demo UI test (`DemoTakeTests`, slowed with pauses, live API) in `ios/LaCarteUITests/`: owned by `qa-validator`,
  to be requested by the manager. Shots A1–A8 and B4 come from it.
- Specs 006 (pull to refresh, B4), 008 (setup) merged; 007 (widget, A9 / B5) built.

## Decisions (user, 2026-11-21)

Simulator only (no real-iPhone takes) · plain ffmpeg (no Remotion) · Video B side by side · the real 1-day streak ·
end cards show `github.com/me-env/la-carte` · each MP4 under 10 MB · all content in English.
