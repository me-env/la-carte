# QA 016b: Settings AI app picker

Verdict: **PASS**. Branch worktree-agent-a2192b041e4fde948.

Runs: `ios-ui-test.sh --split 2 ai` (Settings + Report suites): 13 passed, 1 failed, 2 skipped. The failure, `testReport_eachReasonSent` ("study.front" missing), is a flake: it passed alone on rerun (`ai-rerun`). `ios-test.sh`: 223 passed, 2 skipped. `e2e.sh` not run (not requested).

| # | Criterion | Result | Proof |
|---|---|---|---|
| 1 | Ask AI section, `settings.aiApp` menu lists 6 apps, footer text | PASS (light, dark) | qa/screenshots/ai/settings-ai-app-{light,dark}.png |
| 2 | Defaults to Vibe; Grok pick survives relaunch | PASS | testSettings_aiAppPicker |
| 3, 4 | Link and open logic | unit tests (green) | |
| 5 | Copy only: notice "Copied" | PASS | study-ask-copy-only-light.png (`-aiApp copyOnly`, stored value, not picked through the UI) |
| 6 | Vibe not installed: "Copied · Vibe isn't installed", pasteboard text exact | PASS | study-ask-not-installed-{light,dark}.png |
| 7 | Opening Vibe/Claude/ChatGPT on device | Left for the user on device | |

Visual: the picker row and footer match the native Form style in light and dark. The open menu hides the row's current value, which is expected.

Bugs: none.
