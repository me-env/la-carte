# Dev velocity: running agents in parallel

Owner: `dev-velocity`. Several agents share one Mac, one working tree, one booted simulator and one
DerivedData per project, and pools of test simulators. These rules keep them from blocking or breaking each other.

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
| `sim-<SIMULATOR>-<OS>` | UI pool slot 1 (`iPhone 17 Pro`) | `ios-ui-test.sh` **test phase only** (via `_sim-pool.sh`; older scripts take it directly) |
| `sim-la-carte-ui-<n>-<OS>` | UI pool slots 2..5 (`la-carte-ui-2` … `-5`) | `ios-ui-test.sh` test phase via `SIM_POOL=ui _sim-pool.sh` |
| (several UI slots at once) | one run sharded over the free UI slots | `ios-ui-test.sh --split` (`ios-ui-test-split.sh`): builds once, then one shard per free slot |
| `sim-<UNIT_SIMULATOR>-<OS>` | unit-test pool slot 1 (`iPhone 17`) | `ios-test.sh` (via `_sim-pool.sh`; older scripts take it directly) |
| `sim-la-carte-unit-<n>-<OS>` | unit-test pool slots 2..3 (`la-carte-unit-2`, `-3`) | `ios-test.sh` via `_sim-pool.sh` |

Order is always build lock, then simulator lock, so no deadlock. `<checkout>` is a hash of the repo path:
each git worktree (`.claude/worktrees/*`) has its own DerivedData and build locks, while simulator locks are
global (`/tmp/la-carte-locks`): unit and UI runs from any worktree take the first free device of their pool
(below). `OS=27.0`
resolves to the same lock as `latest` when 27.0 is the newest runtime.

## What can run at the same time

| While this runs ↓ | `ios-build.sh` | `ios-test.sh` | `ios-ui-test.sh` / `e2e.sh` | `api-test.sh` / `api-dev.sh` |
|---|---|---|---|---|
| `ios-ui-test.sh` / `e2e.sh`, building (~1–3 min) | waits | **yes** | same checkout waits; other worktrees yes | yes |
| `ios-ui-test.sh` / `e2e.sh`, testing (~20–30 min) | **yes** | **yes** | **yes, up to 5 at once** | yes |
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
- UI tests run on their own **pool** (`SIM_POOL=ui scripts/_sim-pool.sh`): slot 1 is `SIMULATOR` (`iPhone 17 Pro`,
  same lock as before); slots 2..`UI_POOL_SIZE` (default 5) are `la-carte-ui-<n>`, **same model and runtime**, so
  screenshots and pixel checks are identical whichever slot a run gets. Same first-free / retry / `LOCK_TIMEOUT`
  rules as the unit pool. `e2e.sh` gets it through `ios-ui-test.sh`; callers change nothing. `UI_POOL_SIZE=1`
  turns it off (CI does).
- **Simulator budget: about 8 booted at once** (5 UI slots + 3 unit slots). In-run workers
  (`-parallel-testing-enabled`, `UI_WORKERS`) each boot one more clone, so **`UI_WORKERS` defaults to 1**; set
  `UI_WORKERS=N` only when about N UI slots are idle (e.g. a lone full-suite run), keeping running UI runs ×
  workers + unit runs ≤ 8. All three numbers are env-tunable: `UI_POOL_SIZE`, `UNIT_POOL_SIZE`, `UI_WORKERS`.
  Workers take whole test classes on clones Xcode creates and deletes per run, so each UI test class stands alone
  (own stub servers on OS-picked ports, no order between classes).
- **Bound a run** with `scripts/_timeout.sh <seconds> <command…>` (macOS has no `timeout`): kills the command's
  whole process group (xcodebuild included) and exits 124; its locks drop with it.

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

### UI pool: sizing (2026-11-21)

Before: every `ios-ui-test.sh` / `e2e.sh` queued on `sim-iPhone-17-Pro-latest`; at 18:47 one run (`010-mock`,
since 17:52) held it and 6 more QA runs were waiting behind it. After: with slot 1 still held, `pool-check`
took slot 2 at once, created `la-carte-ui-2`, and passed (1 test, 83.6 s). Measured during it: 2 booted
simulators, 56–61% memory free, but load 130 on 14 cores from 2 `xcodebuild`s + 11 `swift-frontend`s: **builds,
not simulators, are what saturates CPU**, and memory has room. Hence 5 UI slots + 3 unit slots = 8 booted
simulators at most, `UI_WORKERS=1` by default. Disk: about 1.5–2 GB per slot once used, so 4 UI + 2 unit clones
≈ 12 GB (budget 20 GB); free disk went 38 → 35 GB during the check. Lower `UI_POOL_SIZE` if load or memory
pressure turns out to slow UI runs down (timeouts), rather than adding workers.

## Working tree

Agents spawned with worktree isolation work in `.claude/worktrees/<agent>` (own build locks, shared
simulator locks); everyone else shares the main tree. Either way, don't edit files another agent owns
(see the table in `CLAUDE.md`); `ios/LaCarte.xcodeproj/project.pbxproj` has one editor at a time
(the manager serialises it). A UI suite tests whatever is on disk when its build phase starts.

## Plan (not done yet)

Measured 2026-11-21 (before the user freed disk): iOS 27 runtime 7.5 GB, `iPhone 17 Pro` 5.7 GB, la-carte
DerivedData 1.7 GB app + 1.0 GB kit, `qa/.results` 1.1 GB. 48 GB RAM, 14 cores. Unit-test simulator (`iPhone 17`): 17 MB → 1.6 GB after its first run; `ios-test.sh` took 91 s (114 tests) while a UI suite ran on `iPhone 17 Pro`.

1. ~~Per-agent simulator clones~~: done as the UI pool (above).
2. **Git worktrees** per engineer (`git worktree add "$LA_CARTE_SCRATCH/worktrees/<agent>" -b
   <agent>/<feature>`). Each brings its own DerivedData (about 2.7 GB, on the scratch disk) and its own
   build locks automatically; the simulator locks stay shared. The manager merges.
3. **Housekeeping:** prune old `*.xcresult` after screenshots are exported.
