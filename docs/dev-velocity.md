# Dev velocity: running agents in parallel

Owner: `dev-velocity`. Several agents share one Mac, one working tree, one booted simulator and one
DerivedData per project. These rules keep them from blocking or breaking each other.

## How to wait: you don't, the scripts do

Run `scripts/ios-*.sh` and `scripts/e2e.sh` directly, even while another agent's run is in progress.
They take the locks they need (`scripts/_lock.sh`, macOS `lockf`), print who holds a busy lock, wait, and
then run. Never poll `pgrep xcodebuild`, never `sleep` in a loop, never call `xcodebuild` by hand.

- Set `LACARTE_AGENT=<your agent name>` so waiters see who holds the lock (e.g. `LACARTE_AGENT=qa-validator
  scripts/ios-ui-test.sh 009-mock`).
- `LOCK_TIMEOUT` (seconds, default 3600). On timeout the script exits **75** and prints the holder:
  report that, don't retry in a loop.
- The kernel drops a lock when its command exits or crashes: no stale locks, nothing to clean up.
  Holder notes live in `/tmp/la-carte-locks/*.holder` (informational only).

## Locks

| Lock | Protects | Taken by |
|---|---|---|
| `build-LaCarte-<checkout>` | `ios/LaCarte.xcodeproj` DerivedData ("database is locked" if shared) | `ios-build.sh`; `ios-ui-test.sh` **build phase only** |
| `build-LaCarteKit-<checkout>` | `ios/LaCarteKit` DerivedData (a different folder from the app's) | `ios-test.sh` |
| `sim-<SIMULATOR>-<OS>` | the UI-test simulator (`iPhone 17 Pro`) | `ios-ui-test.sh` **test phase only** |
| `sim-<UNIT_SIMULATOR>-<OS>` | the unit-test simulator (`iPhone 17`) | `ios-test.sh` |

Order is always build lock, then simulator lock, so no deadlock. `<checkout>` is a hash of the repo path:
each git worktree (`.claude/worktrees/*`) has its own DerivedData and build locks, while simulator locks are
global (`/tmp/la-carte-locks`), so UI runs from several worktrees queue for the same device. `OS=27.0`
resolves to the same lock as `latest` when 27.0 is the newest runtime.

## What can run at the same time

| While this runs ↓ | `ios-build.sh` | `ios-test.sh` | `ios-ui-test.sh` / `e2e.sh` | `api-test.sh` / `api-dev.sh` |
|---|---|---|---|---|
| `ios-ui-test.sh` / `e2e.sh`, building (~1–3 min) | waits | **yes** | waits | yes |
| `ios-ui-test.sh` / `e2e.sh`, testing (~20–30 min) | **yes** | **yes** | waits | yes |
| `ios-test.sh` | yes | waits | yes | yes |
| `ios-build.sh` | waits | yes | build waits | yes |

- `ios-ui-test.sh` runs `build-for-testing` (app lock) into a private copy of the test products
  (`<results>/<run>.xctestproducts`, deleted on exit), then `test-without-building` from that copy
  (simulator lock only). So `ios-build.sh` doesn't wait for a whole QA suite, and nothing it builds can
  replace the app under test.
- `e2e.sh` starts its two APIs on free ports picked by the OS (`E2E_PORT` / `E2E_EMPTY_PORT` override),
  so it never clashes with `api-dev.sh` (:8000) or another e2e run. Run names must still be unique
  (`qa/screenshots/<run>`, `<results>/<run>.xcresult`).
- Unit tests run on their own simulator, `UNIT_SIMULATOR` (default `iPhone 17`, iOS 27; on CI it is
  `$SIMULATOR`, the one CI boots), so `ios-test.sh` never waits behind a UI suite. Set `UNIT_SIMULATOR=…`
  to override; if it names the UI simulator, the two scripts share one lock again and queue.

## Big outputs: the scratch disk

Large, regenerable outputs go to `$LA_CARTE_SCRATCH` when it is set and its disk is mounted, else to the
usual in-repo paths. Set it per machine in `scripts/.local.env` (gitignored, never read on CI; worktrees read the main
checkout's copy; results go in a per-checkout subfolder), e.g.
`LA_CARTE_SCRATCH="${LA_CARTE_SCRATCH:-/Volumes/<ssd>/la-carte}"`. `_ios-env.sh` falls back by itself
when the parent folder is missing (disk unplugged).

| Output | With scratch | Without |
|---|---|---|
| UI-test result bundles (`ios-ui-test.sh`, `e2e.sh`) | `$LA_CARTE_SCRATCH/qa-results/<checkout>/<run>.xcresult` | `qa/.results/<run>.xcresult` |
| Future per-agent DerivedData / worktrees (plan below) | `$LA_CARTE_SCRATCH/DerivedData-<agent>`, `$LA_CARTE_SCRATCH/worktrees/<agent>` | internal disk |

Screenshots stay in `qa/screenshots/<run>/` (reports link them). Other big outputs (marketing
recordings/renders, design-review caches) should read `$LA_CARTE_SCRATCH` the same way (source
`scripts/_ios-env.sh` and use the variable when it is non-empty); their owners adopt it when they next touch
those scripts. Simulators and runtimes stay where Xcode manages them. Existing data was not moved.

Measured 2026-11-21: one `-only-testing` UI run plus two `ios-build.sh` started 3 s later. The builds
waited about 20 s for the UI build phase, then ran one after the other (+23 s, +33 s) while the UI test ran;
the UI test passed at +44 s. `ios-test.sh` (114 tests, 91 s) passed on `iPhone 17` during a UI suite.

## Working tree

Agents spawned with worktree isolation work in `.claude/worktrees/<agent>` (own build locks, shared
simulator locks); everyone else shares the main tree. Either way, don't edit files another agent owns
(see the table in `CLAUDE.md`); `ios/LaCarte.xcodeproj/project.pbxproj` has one editor at a time
(the manager serialises it). A UI suite tests whatever is on disk when its build phase starts.

## Plan (not done yet)

Measured 2026-11-21 (before the user freed disk): iOS 27 runtime 7.5 GB, `iPhone 17 Pro` 5.7 GB, la-carte
DerivedData 1.7 GB app + 1.0 GB kit, `qa/.results` 1.1 GB. 48 GB RAM, 14 cores. Unit-test simulator (`iPhone 17`): 17 MB → 1.6 GB after its first run; `ios-test.sh` took 91 s (114 tests) while a UI suite ran on `iPhone 17 Pro`.

1. **Per-agent simulator clones** for UI work (`xcrun simctl clone "iPhone 17 Pro" "iPhone 17 Pro <agent>"`,
   `SIMULATOR=` per agent). About 2–5 GB each as they get used (they must live on the internal disk). It
   lets two UI suites run at once; CPU allows about 2. Worth it only if QA and another agent often need UI
   runs at the same time.
2. **Git worktrees** per engineer (`git worktree add "$LA_CARTE_SCRATCH/worktrees/<agent>" -b
   <agent>/<feature>`). Each brings its own DerivedData (about 2.7 GB, on the scratch disk) and its own
   build locks automatically; the simulator locks stay shared. The manager merges.
3. **Housekeeping:** prune old `*.xcresult` after screenshots are exported.
