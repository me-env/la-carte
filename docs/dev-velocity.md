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
| `sim-<UNIT_SIMULATOR>-<OS>` | unit-test pool slot 1 (`iPhone 17`) | `ios-test.sh` (via `_sim-pool.sh`; older scripts take it directly) |
| `sim-la-carte-unit-<n>-<OS>` | unit-test pool slots 2..3 (`la-carte-unit-2`, `-3`) | `ios-test.sh` via `_sim-pool.sh` |

Order is always build lock, then simulator lock, so no deadlock. `<checkout>` is a hash of the repo path:
each git worktree (`.claude/worktrees/*`) has its own DerivedData and build locks, while simulator locks are
global (`/tmp/la-carte-locks`), so UI runs from several worktrees queue for the same device; unit runs take
the first free device of the unit pool (below). `OS=27.0`
resolves to the same lock as `latest` when 27.0 is the newest runtime.

## What can run at the same time

| While this runs ↓ | `ios-build.sh` | `ios-test.sh` | `ios-ui-test.sh` / `e2e.sh` | `api-test.sh` / `api-dev.sh` |
|---|---|---|---|---|
| `ios-ui-test.sh` / `e2e.sh`, building (~1–3 min) | waits | **yes** | waits | yes |
| `ios-ui-test.sh` / `e2e.sh`, testing (~20–30 min) | **yes** | **yes** | waits | yes |
| `ios-test.sh` | yes | yes, up to 3 at once (same checkout: waits) | yes | yes |
| `ios-build.sh` | waits | yes | build waits | yes |

- `ios-ui-test.sh` runs `build-for-testing` (app lock) into a private copy of the test products
  (`<results>/<run>.xctestproducts`, deleted on exit), then `test-without-building` from that copy
  (simulator lock only). So `ios-build.sh` doesn't wait for a whole QA suite, and nothing it builds can
  replace the app under test.
- `e2e.sh` starts its two APIs on free ports picked by the OS (`E2E_PORT` / `E2E_EMPTY_PORT` override),
  so it never clashes with `api-dev.sh` (:8000) or another e2e run. Run names must still be unique
  (`qa/screenshots/<run>`, `<results>/<run>.xcresult`).
- Unit tests run on a **pool of simulators** (`scripts/_sim-pool.sh`), never the UI one: slot 1 is
  `UNIT_SIMULATOR` (default `iPhone 17`, iOS 27, same lock as before, so worktrees with older scripts share it
  correctly); slots 2..`UNIT_POOL_SIZE` (default 3) are `la-carte-unit-2`, `la-carte-unit-3`, same device type
  and runtime, created by the script on first use (about 2 GB each once used). A run takes the first free slot
  without waiting; if all are busy it prints the holders and retries every 2 s up to `LOCK_TIMEOUT`. Runs from
  one checkout still queue on that checkout's DerivedData lock. `UNIT_POOL_SIZE=1` turns the pool off (CI does).
- `ios-test.sh` passes `-collect-test-diagnostics never`: after a failing or crashing test, Xcode otherwise runs
  `simctl diagnose` (up to 10 min) while still holding the simulator.
- UI suites stay on one device: no UI pool until two UI suites at once are measured to be fine (see Plan 1).

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

### Unit-test pool: before / after (2026-11-21)

Before (one unit simulator, 17:30–17:46): 6 worktree/main runs of `ios-test.sh` queued. Slot holder acquired
17:35:16 after waiting 2 min 41 s; its tests took about 55 s, then `simctl diagnose` held the device another
10 min. At 17:46 four runs had waited 9–13 min for `sim-iPhone-17-latest` and two more 10–14 min for their
checkout's DerivedData lock behind them. A test phase is 36–61 s (5 xcresults), incremental build about 15 s,
so the device, not the build, was the bottleneck. The UI simulator had 1 run waiting 8 min.
Machine at the peak: load average 46 (14 cores), 45 GB RAM used, 12 GB compressed.

After: with slot 1 still busy and 4 runs queued on it (older scripts), a new `ios-test.sh` took slot 2 at once:
101 passed in 91.9 s, 102 s end to end, 0 s wait. Three concurrent dummy holders: the third saw "all 3 busy" and
timed out with exit 75 as configured. Disk: `la-carte-unit-2` 2.0 GB after one run, `-3` 17 MB until used.

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
   lets two UI suites run at once; CPU allows about 2, but on 2026-11-21 load hit 46 on 14 cores with 12 GB of
   memory compressed while 5 worktrees built, so measure two suites on a quiet machine first (`_sim-pool.sh` can
   grow a UI pool then). Worth it only if QA and another agent often need UI
   runs at the same time.
2. **Git worktrees** per engineer (`git worktree add "$LA_CARTE_SCRATCH/worktrees/<agent>" -b
   <agent>/<feature>`). Each brings its own DerivedData (about 2.7 GB, on the scratch disk) and its own
   build locks automatically; the simulator locks stay shared. The manager merges.
3. **Housekeeping:** prune old `*.xcresult` after screenshots are exported.
