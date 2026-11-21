# Launch videos: tooling decision

Goal: two 30–60 s minimalist videos (A: app demo, B: "ask an agent to add cards") plus a README GIF,
built with scriptable, free tooling so takes are repeatable after every UI change.
Researched November 2026. Version numbers are the latest found then; check `--help` before scripting.

## 1. Recommended pipeline

| Stage | Tool | Why |
|---|---|---|
| App capture | `xcrun simctl io recordVideo` (Xcode 27) + `simctl status_bar` | Pixel-perfect, free, scriptable, no device needed |
| Repeatable takes | A dedicated XCUITest "demo" test (mock API, slowed with `sleep`s) | Reuses `LaCarteUITests` ids + `StubAPIServer`. Same take every time |
| Terminal / agent | **VHS** v0.12.x (`.tape` → MP4/WebM/GIF), running the **real** Claude Code against the real MCP server | Scripted framing + real MCP call = honest and clean |
| Composition | **ffmpeg** (trim, CFR, pad on a flat background, hstack/xfade, burn captions) | Free, one shell script, enough for a calm look |
| Optional polish | **Remotion** v4 (device frame, eased zooms, captions as React) | Only if ffmpeg looks too plain. Free for individuals and companies of ≤3 people |
| GIF | ffmpeg → PNG frames → **gifski** (1.34) | Best GIF quality per byte |
| Hosting | MP4 (H.264) via drag-and-drop into the README on GitHub (user-attachments URL) | Plays inline. **10 MB limit** on free plans |

### Sketch (would live in `scripts/marketing/`)

```bash
# 0. Clean status bar on the booted sim
xcrun simctl status_bar booted override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl ui booted appearance light            # repeat the take with dark

# 1. App take: start recording, run the demo UI test, stop with SIGINT (finalizes the file)
xcrun simctl io booted recordVideo --codec=h264 --mask=ignored --force raw/app.mov &
REC=$!; scripts/ios-ui-test.sh demo   # e.g. -only-testing:LaCarteUITests/DemoTakeTests
kill -INT $REC; wait $REC

# 2. Normalize: simulator video has a variable frame rate. Convert to 60 fps CFR and trim
ffmpeg -i raw/app.mov -vf "fps=60,scale=-2:1920" -c:v libx264 -crf 18 -pix_fmt yuv420p raw/app60.mp4

# 3. Frame it: rounded phone on the flat warm brand background (color from the design-system tokens)
ffmpeg -i raw/app60.mp4 -i assets/bezel.png -filter_complex \
  "color=c=#F4EFE6:s=1920x1080:r=60[bg];[0]scale=-2:900[p];[bg][p]overlay=(W-w)/2:(H-h)/2:shortest=1[v];[v][1]overlay=..." \
  -c:v libx264 -crf 20 -preset slow -movflags +faststart -an out/app-demo.mp4

# 4. Agent take (B)
vhs agent.tape                         # Output out/agent.mp4 (+ .gif)
ffmpeg -i out/agent.mp4 -i raw/app60-refresh.mp4 -filter_complex "[0][1]hstack" out/agent-demo.mp4

# 5. README GIF (keep it ~600 px wide, 15 fps, < 5 MB)
ffmpeg -i out/app-demo.mp4 -vf "fps=15,scale=600:-1" frames/%04d.png
gifski --fps 15 --width 600 --quality 80 -o out/readme.gif frames/*.png
```

`agent.tape` (VHS) sketch: `Require claude`, `Set Theme`, `Set FontSize 28`, `Set Padding 40`,
`Set WindowBar Rings`, `Type "claude"`, `Enter`, `Wait+Screen /for shortcuts|>/`,
`Type "Add these to my deck: la pomme, le chien, la mer"`, `Enter`,
`Wait+Screen@60s /add_cards|Added/`, `Sleep 2s`. Use `Hide`/`Show` around setup (cd, MCP config).
It types into a real shell, so the MCP call is real. Only the pacing is scripted.

### What still needs a human

- **Widget on the home screen.** `simctl` has no command to add a widget. The documented flows are
  "Xcode run of the widget scheme places it" or edit mode → "+" → widget gallery. Do it **once by hand**
  in a dedicated demo simulator, then reuse that simulator (or `simctl clone` it) for every take.
  Recording, refreshing, and the rest can then be scripted. Note: the widget (spec 007) is not built yet.
- **Real-device take** (optional, nicer touch feel and real widget): QuickTime → New Movie Recording →
  pick the iPhone over USB. Or use on-device Control Center recording and AirDrop the file. Manual, not
  scripted. Then the same ffmpeg steps apply.
- **Final pick of takes, timing, and caption wording.** Watch each render once before publishing.
- **Uploading the MP4 to GitHub** to get a `user-attachments` URL needs the web editor. There is no CLI path.

## 2. Alternatives considered

| Need | Option | Verdict |
|---|---|---|
| Capture | simctl recordVideo | **Chosen.** Flags: `--codec h264/hevc` (hevc default), `--mask ignored/black`, `--display`, `--force`. No fps flag; output is VFR |
| | QuickTime over USB (real iPhone) | Best for the real widget and haptics feel. Manual |
| | On-device screen recording | Shows a red indicator, gets status-bar noise, manual |
| Driving | XCUITest demo test | **Chosen.** Deterministic, uses existing ids |
| | Hand taps / AppleScript clicks | Not repeatable |
| Frames & zoom | ffmpeg overlay + PNG bezel | **Chosen.** Free and scriptable. Bezel PNGs come from Apple Design Resources (check the license terms for marketing use) |
| | Remotion | Best code-driven polish (springs, zooms, captions). Source-available license: free for teams of ≤3 |
| | Motion Canvas (MIT) | Free and good for animated explanations. Smaller community and less video-editing oriented |
| | Screen Studio | Beautiful auto-zoom and device frames, iPhone over USB. ~$29/mo, manual, macOS only |
| | Rotato, CleanShot X | 3D mockups / quick captures. Paid and manual |
| Terminal | **VHS** | **Chosen.** Tape = code. MP4/WebM/GIF/frames output. `Wait` on regex avoids guessed sleeps |
| | asciinema 3.0 + agg | Records a fully real interactive session (`.cast`). agg → GIF (gifski inside). Good fallback if VHS's PTY trips Claude Code's TUI |
| | Remotion fake terminal | Prettiest, but it is a re-enactment. Only OK if labelled. Avoid for honesty |
| | Raw macOS screen capture of Terminal | Real but noisy (window chrome, cursor). Needs cropping |
| Editing | ffmpeg | **Chosen** for cuts, stacks, crossfades, captions (`drawtext`/`subtitles`) |
| | DaVinci Resolve (free) | Fallback for one-off manual polish. Not reproducible |
| GIF format | gifski | **Chosen.** Shrinking the size helps more than lowering quality |
| | Animated WebP / AVIF | Much smaller, and GitHub renders them as `<img>`. Use if the GIF is over ~5 MB |

Captions: short sentence-case lines, the app's font, bottom-centre, no boxes, about 2 s each. Burn them in
(README videos autoplay muted). Keep 1080p H.264 + `+faststart` + no audio. That keeps 45 s well under 10 MB.

## 3. Open questions

1. Simulator-only, or a real-iPhone take for the widget/hero shot?
2. Plain ffmpeg framing, or invest in Remotion for zooms and nicer captions (adds a Node project under `marketing/`)?
3. Video B layout: side by side (terminal left, phone right), or sequenced (terminal → cut to app)?
4. Which agent client to show: Claude Code (terminal, scriptable with VHS) or Claude Desktop (manual screen capture)?
5. Which API to use for the takes: a throwaway local API seeded by `scripts/e2e.sh`, or the production one? Local is recommended, so no real data appears.
6. Language of the demo words (French nouns fit the "la-carte" theme)?
7. GitHub plan: on a free plan, each README video must be ≤ 10 MB.

## 4. Sources

- simctl recordVideo flags: https://developer.apple.com/videos/play/wwdc2020/10647/ ·
  https://sarunw.com/posts/take-screenshot-and-record-video-in-ios-simulator/ ·
  https://developer.apple.com/forums/thread/694901
- Simulator VFR → CFR: https://ffmpeg.org/pipermail/ffmpeg-trac/2023-August/066867.html ·
  https://www.avanderlee.com/workflow/capture-ios-simulator-video-app-preview/
- Status bar overrides: https://www.jessesquires.com/blog/overriding-status-bar-settings-ios-simulator/ ·
  https://github.com/jessesquires/nine41
- Widgets (no simctl add, manual or Xcode placement): https://developer.apple.com/documentation/widgetkit/debugging-widgets
- Device bezels: https://developer.apple.com/design/resources/ ·
  https://9to5mac.com/2026/09/09/apple-updates-design-resources-with-iphone-duo-and-iphone-18-pro-product-bezels/
- VHS: https://github.com/charmbracelet/vhs · https://github.com/charmbracelet/vhs/releases
- asciinema 3.0 / agg: https://blog.asciinema.org/post/three-point-o/ · https://docs.asciinema.org/manual/agg/
- gifski: https://docs.rs/crate/gifski/latest · https://github.com/ImageOptim/gifski
- Remotion license: https://www.remotion.dev/docs/license/faq · https://github.com/remotion-dev/remotion/blob/main/LICENSE.md
- Motion Canvas vs Remotion: https://www.remotion.dev/docs/compare/motion-canvas
- Screen Studio: https://screen.studio/ · https://trainn.co/blog/screen-studio-pricing/
- GitHub attachment limits (10 MB video on free plans; MP4/MOV/WebM):
  https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files ·
  https://github.com/orgs/community/discussions/46513
