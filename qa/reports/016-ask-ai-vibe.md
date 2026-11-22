# QA: 016 Ask AI, Vibe amendment (open + copy, `-noticeSeconds`)

Verdict: **PASS**
Date: 2026-11-22 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-ad39479eb3be64f0f` (b98bac7)
Runs: `qa/screenshots/016-vibe-mock/`
Commands: `scripts/ios-ui-test.sh --split 016-vibe-mock -only-testing:LaCarteUITests/ReportUITests` (9 passed, 0 failed,
1 skipped: `testReport_dropCard_liveAPI`, which needs `scripts/e2e.sh`), `scripts/ios-test.sh` (279 passed, 0 failed, 5 skipped).
Scope as briefed: ReportUITests only. No e2e run and no full suite.

## Test changes (ReportUITests)
- New `longNotices = ["-noticeSeconds", "10"]`, passed by every test that waits for a notice: `testAsk_copiesCardText`,
  `testAsk_copyOnlyShowsCopied`, `testReport_eachReasonSent`, `testReport_lastCardShowsReportedThenCaughtUp`.
  Waits for the counter to come back are now `noticeSeconds + 5`. The poll for the last card is now `noticeSeconds + 10`.
  Notice waits went from 3 s to 5 s.
- `testAsk_copiesCardText` launches with `-aiApp vibe` explicitly, so it tests the Vibe path even if the stored value
  changes. SettingsUITests still covers Vibe as the default. The test also checks that the notice is still up about
  3.5 s after it appears. That proves `-noticeSeconds` lengthens it past the 2 s default.
- `testReport_heldAfterRefresh` and the live test keep the default 2 s, so the default length is still exercised.
- MarketingUITests also uses Ask, but I left it unchanged. It records the demo video, and longer notices would slow
  its pacing. It uses `-aiApp copyOnly` and waits 3 s for "Copied", which is the same flake risk on CI.

## Acceptance criteria (amended 3, 4, 7)
| # | Result | Evidence |
|---|---|---|
| 3 | PASS (unit) | `AIAppTests`: Vibe link is exactly `https://chat.mistral.ai/chat/`, with no `?q=`. A UI test can't see the URL: the simulator has no app that claims the universal link, and `universalLinksOnly` means nothing opens. `StudyReportTests.theDefaultVibeNotInstalledSaysSo` checks that `open` gets `AIApp.vibe.link(…)` |
| 4 | PASS | UI: `study-ask-not-installed-{light,dark}.png` show "Copied · Vibe isn't installed" in the counter slot (`.meta`, secondary ink, centered, no pink). The pasteboard text matches the 016 template exactly (`XCTAssertEqual`, `study-ask-pasted-light.png`: lowercase id, Question/Answer lines, cursor on the second empty line). The notice is still up after 3.5 s with `-noticeSeconds 10`, and the counter comes back afterwards. Unit: copy comes before open |
| 5 | PASS | `study-ask-copy-only-light.png` |
| 6 | PASS | as #4: the app stays in front, the card stays revealed, the ratings stay enabled, no writes are sent |
| 7 | Left for the user | On the device: Ask with Vibe opens Vibe, and pasting gives the exact text. Claude and ChatGPT open prefilled |

## Visual review
- [x] background edge to edge, light + dark
- [x] the notice is quiet and doesn't compete with the card; no default blue tint
- [x] circle buttons aligned
- [x] long answer and pasted text wrap, nothing truncated
- [ ] Dynamic Type: deferred (docs/testing.md)

## Bugs
None.
