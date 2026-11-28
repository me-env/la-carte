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
- **Maximise simulators, cap builds.** Builds are what overload the Mac (each `xcodebuild` uses every core;
  26 at once hit load 730). So `_lock.sh --slots` gives a machine-wide semaphore (`BUILD_SLOTS`, default 2, lock
  dir `LOCK_DIR` = `/tmp/la-carte-locks`, shared by every worktree): `ios-build.sh`, the build step of
  `ios-ui-test.sh` / `--split`, and `ios-test.sh`'s `xcodebuild test` hold a slot, and a third waits printing
  `🔒 waiting for build slot`. Each build gets `-jobs cores/BUILD_SLOTS` (7 on 14 cores; `BUILD_JOBS` overrides).
  Test-without-building steps take no slot: the simulator pools govern them. Worktrees on old branches keep old
  scripts (uncapped) until they merge main.
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
- **Simulator budget: about 8 booted at once** (5 UI slots + 3 unit slots). Parallel workers
  (`UI_WORKERS`) each use one more pool slot, so **`UI_WORKERS` defaults to 1**; set
  `UI_WORKERS=N` only when about N UI slots are idle (e.g. a lone full-suite run), keeping running UI runs ×
  workers + unit runs ≤ 8. All three numbers are env-tunable: `UI_POOL_SIZE`, `UNIT_POOL_SIZE`, `UI_WORKERS`.
  `UI_WORKERS=N` makes `ios-ui-test.sh` run `--split N` on the warm pool simulators. Xcode's own parallel clones
  (`-parallel-testing-enabled`) are never used: they boot cold every run and Apple's PosterBoard crashes in them
  (a macOS crash pop-up each). A missing pool device (slot 1 included) is created and booted once, under its lock,
  so no test run pays a first boot.
- **Regrowth trim:** when a run releases a pool device bigger than `SIM_TRIM_GB` (default 8; used devices had grown
  to 10–17 GB), `_sim-pool.sh` erases it and boots it once more (about 20 s, still under its lock), then the
  waiter gets it. Not on CI.
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
| Future worktrees (plan below) | `$LA_CARTE_SCRATCH/worktrees/<agent>` | internal disk |

Screenshots stay in `qa/screenshots/<run>/` (reports link them). Other big outputs (marketing
recordings/renders, design-review caches) should read `$LA_CARTE_SCRATCH` the same way (source
`scripts/_ios-env.sh` and use the variable when it is non-empty); their owners adopt it when they next touch
those scripts.

### This Mac: DerivedData lives on an external SSD (2026-11-22)

Machine-wide setting, not in the repo (CI and other Macs are unaffected):
`defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation` points at `<external SSD>/Xcode/DerivedData`
(Xcode and every `xcodebuild` without `-derivedDataPath`). If the SSD is not mounted, builds fail to create
DerivedData: plug it in, or `defaults delete com.apple.dt.Xcode IDECustomDerivedDataLocation` to go back to
`~/Library/Developer/Xcode/DerivedData`.

### This Mac: simulator devices live on the external SSD (2026-11-23)

Set per machine in `scripts/.local.env` (gitignored, never read on CI):
`LA_CARTE_SIM_DEVICES="${LA_CARTE_SIM_DEVICES:-/Volumes/<ssd>/la-carte/simulators}"`.
Mechanism: **one APFS disk image per device**, `$LA_CARTE_SIM_DEVICES/<UDID>.sparsebundle`, mounted *at* the
device's own folder `~/Library/Developer/CoreSimulator/Devices/<UDID>` (`hdiutil attach -nobrowse -mountpoint`).
CoreSimulator lists, boots, erases and tests them like local devices; device names are unchanged, so agents change
nothing. `_ios-env.sh` mounts any image that isn't (after a reboot or replug; ~0.1 s each) before every iOS script.
- **Why not symlinks** (the first version, 2026-11-23, d511eb4): a linked device folder has two paths, and the
  simulator's processes use both. `XCUIDevice.shared.appearance = .dark` is written by `testmanagerd` through
  `~/Library/…/<UDID>/data/…` while SpringBoard's style arbiter reads the same preferences domain through
  `/Volumes/…/<UDID>/data/…`; cfprefsd keys domains by path, so SpringBoard never saw the change and every dark
  screenshot rendered light (#F9FAF5 instead of #1A1A1A, no error). A mount has one path. Linking the whole
  `Devices` folder would have the same problem. (The images are also APFS like the internal disk; the SSD is HFS+.)
- **Dark mode also needs the appearance preference at boot.** SpringBoard's style arbiter only follows
  `XCUIDevice.appearance` if `data/Library/Preferences/com.apple.uikitservices.userInterfaceStyleMode.plist`
  existed when it started. A new or erased device has no such file, so its first boot ignores every switch (sim log:
  `testmanagerd … Updating appearance mode to: 2` with no `Arbiter changing style` after it); old devices had it
  from earlier runs. `sim_prewarm` writes it (`simctl spawn … defaults write`), and `_sim-pool.sh` runs
  `sim_appearance_ready` before each run: file missing → one boot to write it, then shut down (~30 s, once). This
  hits any fresh simulator, not only the SSD ones (CI's included).
- Moving a used device into an image (`sim_to_image`) keeps only `device.plist` and **erases** it: its databases
  (LaunchServices, containers, nsurlsessiond) store absolute paths, and a copied device kept writing app data to the
  old folder.
- An image can't be detached while CoreSimulatorService has the device open (`hdiutil detach` says busy): leave
  them mounted. A sparse bundle doesn't shrink when the device is erased (measured: 2.25 GB before and after),
  so each image stays at its high-water mark, about `SIM_TRIM_GB` + one run (~10 GB, ~100 GB for 10 devices).
- `scripts/sim-devices.sh` creates the team's devices if missing (iOS 27: `iPhone 17 Pro`, `iPhone 17`,
  `la-carte-ui-2..5`, `la-carte-unit-2..3`; iOS 26.5: `iPhone 17 Pro`, `iPhone 17`), each in its image, and boots
  it once; devices still linked the old way are moved into images. `_sim-pool.sh` creates missing pool devices the
  same way (`sim_create` in `_ios-env.sh`). A device created by hand or by Xcode lands on the internal disk: prefer
  the scripts.
- **SSD not mounted:** every iOS script stops at once with exit **78** and "❌ The simulators live in … not mounted":
  nothing runs and nothing is recreated on the internal disk. Plug the SSD in and rerun. (Xcode by hand would show
  the devices missing or empty; don't recreate them, plug the SSD in.)
- **Simulator service started before the images** (2026-11-28, after a reboot: `simctl` listed 1 device of 11, runs
  failed with "no simulator for the destination"): `scripts/_sim-service.sh` (run by `_ios-env.sh`, ~0.2 s) restarts
  CoreSimulatorService once when a mounted image isn't listed, only if no simulator is booted and no `xcodebuild` or
  Simulator app runs (any project); otherwise it warns, and `sim_create` refuses to create a device (`_sim-pool.sh`
  exits 72, `sim-devices.sh` skips it), since it may exist already.
- **Duplicate devices** (2026-11-28: a second iOS 27 `iPhone 17`, made by the pool at 13:26 while the service didn't
  list the images, before that guard existed; `name=iPhone 17,OS=latest` then matched two devices and `ios-test.sh`
  failed with "Unable to find a device"): pool runs target their device by UDID, slot 1 too, and with two devices of
  one name take the lowest UDID and warn. To remove the extra one, holding that slot's lock:
  `xcrun simctl shutdown <udid>`, `hdiutil detach` its folder, `xcrun simctl delete <udid>`, then delete
  `<udid>.sparsebundle`. In that order: `simctl delete` on a still-mounted device fails (it can't move the mount
  point) and leaves an empty `Deleting-*` folder.
- Measured, `LaunchUITests` (4 tests) and full `ios-test.sh`, under heavy load from other agents (load 200–600):
  internal disk, warm device: 53.0 s and 5.3 min (283 tests). SSD: 54.2 s and 5.2 min (289 tests); per test
  7.0–7.7 s vs 6.6–6.8 s. The very first UI run after the migration took 114.6 s (one-off: its device had only been
  booted once; per-test times were normal). No steady-state penalty.
- Migration 2026-11-23: all 59 old devices deleted (98 GB on the internal disk, including the iOS 17/18 sets and an
  iOS 18.2 `iPhone 16 Pro` of 17 GB), the 10 above recreated fresh on the SSD and booted once (125 s in parallel).
  Free space on the internal disk: 6.2 GB before, 103 GB after (APFS freed the deleted data over ~15 min).
- Changing devices machine-wide: hold every `sim-*` lock **only for the steps that need it** (the migration held
  them 2.5 h because its "all held" watcher, `tail -f | grep -m1`, never exited: `tail -f` only notices the closed
  pipe on its next write. Wait on a command that ends by itself instead).

### Xcode update mid-session (recovery, 2026-11-22: 27.0 -> 27.2)

Symptoms: "CoreSimulator is out of date (old < new)", and macro targets (swift-perception, TCA, dependencies)
fail with "Unable to resolve Swift module dependency ... 'SwiftSyntax'". Every running build/UI run fails; nothing
to save, so recover at once:
1. CoreSimulatorService must relaunch on the new framework: `killall -9 com.apple.CoreSimulator.CoreSimulatorService`
   (it restarts on the next `simctl`). Check `xcrun simctl list runtimes` and that the `la-carte-ui-*` /
   `la-carte-unit-*` pool devices are still listed. Runtimes don't change with a point release (27.2 kept iOS 27.0).
2. Stale build products: for each checkout that fails, delete only its `<DerivedData>/LaCarte-<hash>/Build`
   (or `LaCarteKit-<hash>/Build`) under that checkout's build lock:
   `scripts/_lock.sh build-LaCarte-<id> rm -rf <dir>/Build` (`build-LaCarteKit-<id>` for the package), with
   `<id>` = `printf %s <checkout root> | cksum | cut -d' ' -f1`. (Sourcing `_ios-env.sh` from zsh gives a wrong
   id: it needs bash's `BASH_SOURCE`.) Each checkout's folder: `WorkspacePath` in `<dir>/info.plist`.
   Keep `SourcePackages/` (the new swift-syntax prebuilt for the new compiler downloads next to the old one),
   don't wipe the shared `ModuleCache.noindex` (other projects use it). Don't delete `SourcePackages/prebuilts`
   by hand; if it was deleted, the next build re-fetches it.
3. Rebuild: `scripts/ios-build.sh` (~25 s warm after the wipe), `scripts/ios-test.sh`.

### Hung builds: clang-stat-cache / fseventsd (2026-11-26)

Symptom: both build slots held 80+ min by `xcodebuild`s at 0% CPU, each waiting on a child
`clang-stat-cache <SDK> -o <DerivedData>/SDKStatCaches.noindex/*.sdkstatcache` (also hit a non-la-carte build).
Cause: when that cache file already exists, `clang-stat-cache` replays FSEvents history since the cache was written
and sits in `CFRunLoopRun` until fseventsd answers. fseventsd (uptime 31 days) was stuck in state `U` and never
answered, so every build after the first hung forever. A fresh cache (file absent) builds in ~2 s; reproduce with
`clang-stat-cache <dir> -o x.cache` twice (2nd hangs). Later even `xcodebuild` itself hung at 0% CPU in
`FSEventStreamStart` (`sample <pid>` shows `f2d_register_rpc`): it starts a file watcher for every local Swift
package while opening the project (`IDESwiftPackage.createPackageDirectoryFileSystemWatcher`, our LaCarteKit), and
every `FSEventStreamStart` on the Mac blocks while fseventsd is in `U`. The package flags
(`-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates`) don't avoid it
(measured: `xcodebuild -list` hangs with and without them). `sudo killall fseventsd` doesn't kill a `U` process:
only a reboot fixes it.
- Workaround until the reboot: `scripts/_fsevents-shim.sh` (sourced by `_ios-env.sh`, never on CI). When fseventsd
  is in state `U`, `xcodebuild` resolves to a shim in `/tmp/la-carte-fsevents-shim/`: a copy of Xcode's xcodebuild,
  ad-hoc signed (Apple's copy has library validation, so it ignores `DYLD_INSERT_LIBRARIES`), plus a dylib whose
  `FSEventStreamStart`/`Stop` do nothing. A command-line build doesn't need file watchers. Off with
  `LA_CARTE_FSEVENTS_SHIM=0`, on with `=1`. Worktrees get it once they merge main; older checkouts still hang.
- The shim can't run tests: simulators only accept an xcodebuild with Apple's private entitlements ("DTServiceHubClient
  failed to bless service hub"; an ad-hoc copy with them is killed at launch). `test-without-building` opens no
  project, so the shim hands it to Apple's xcodebuild, which then doesn't hang; plain `xcodebuild test` exits 69 with a
  message. `ios-test.sh` therefore runs build-for-testing + test-without-building while the shim is on (~500 MB
  products copy in a temp dir per run); `ios-ui-test.sh` always does.
- Fail fast: `_lock.sh --slots` prints one line when fseventsd is in `U` (shim active, or "this build will likely stall"),
  checked without a full-table `ps` ("Hung ps").
- Prevention: `BUILD_JOBS_FLAGS` passes `SDK_STAT_CACHE_ENABLE=NO`, so our builds never run clang-stat-cache.
  Worktrees on older branches don't have it until they merge main.
- Guard: `_lock.sh --slots` kills a build whose process tree used < `STALL_CPU` s (5) of CPU over `STALL_MIN` min
  (10; `0` = off), frees the slot and exits 124 with a message naming this section. A live build burns minutes of
  CPU in that window; a hung xcodebuild ~0.1 s/min. Off on CI (`CI` set): test processes run under the simulator's
  launchd, outside the tree, so `xcodebuild test` (scripts/ios-test.sh) during a silent 14 min `ScreenColorTests`
  looked hung and was killed (CI run 45811826958, docs/ci-cd.md). The same can happen locally on a slow test bundle.
- Recovery by hand: kill the hung `clang-stat-cache` and its `xcodebuild` (lockf frees the slot), and delete the
  `*.sdkstatcache` it was waiting on (literal path; regenerable). Don't kill other projects' builds without asking.

### Stuck file coordination (2026-11-26)

Symptom: after the shim fixed FSEvents, `build-for-testing` hung again at 0% CPU from ~11:45 (stall guard, exit
124). `sample`: main thread in `IDEWorkspace initWithFilePath` → `NSFileCoordinator coordinateReadingItemAtURL` →
`_blockOnAccessClaim`. A 10-line test program doing one coordinated read of a scratch file also never returned, so
filecoordinationd (root, not `U`, but no sudo for us to restart it) stopped answering for every process; the
Xcode app is hung the same way (main thread waiting on an `NSProgress` file subscription). A reboot fixes it;
so would `sudo killall filecoordinationd` (launchd restarts it), which needs the user.
- Workaround: the shim dylib also makes `NSFileCoordinator`'s coordinate methods run their accessor at once and
  `addFilePresenter:` a no-op. A command-line build has no presenters to coordinate with. Same on/off switch as the
  FSEvents part (it's on while fseventsd is in `U`).
- Apple's `xcodebuild test-without-building` of the UI tests (the shim hands tests to it) was not blocked: two
  `StudyUITests` runs passed at 12:07 and 12:12 (5 passed, 2 skipped each, ~62 s).
- `ios-test.sh`'s unit `test-without-building` (LaCarteKit package products) can still hang in SwiftPM's
  `FSEventStream.start` (seen 11:25, 0% CPU for 35+ min, outside the build-slot stall guard). Now covered by the pool
  stall guard and `unstick.sh` ("Stuck runs").

### Stuck simulator audio (2026-11-26)

Symptom: UI runs fail at launch with "Failed to prepare device 'iPhone 17 Pro' for impending launch. (Underlying
Error: Bundle com.apple.CoreSimulator.SimAudioProcessorServices failed to create an audio route descriptor.
Input/output error)". Only on device `iPhone 17 Pro` (42891DD3…, UI pool slot 1), never on `la-carte-ui-*`.
Cause: the host has one `SimAudioProcessorService` per user (started with CoreSimulator, here since 2026-11-22). It
was in state `U` with 34 threads blocked forever in `read()` of that one device's
`data/var/run/com.apple.coresimulator.audio.plist` (`sample` + `lsof -p`): one stuck thread and one open handle per
launch ever attempted there. Each launch on that device asks for its audio route, waits, and gets the I/O error.
Other devices' reads return. Slot 1 is the first slot every run tries, so it failed whenever slot 1 was free:
"more and more often" as fewer other runs held it. Not too many booted simulators (2 at the time), not
CoreSimulatorService itself. Kernel-side reason unknown (same Mac, same weeks as the fseventsd `U` hang); a `U`
process can't be killed, so only a reboot clears it.
- Guard: `_sim-pool.sh` checks `sim_audio_stuck <udid>` (`_ios-env.sh`: `lsof` on the service, ~70 ms) before
  using a slot. A stuck device is skipped with one line naming this section and the run takes the next free slot;
  if every slot is stuck it exits 70 ("reboot"). A healthy read takes microseconds, so an open handle is a stuck one.
- Don't erase, rename or delete the stuck device to work around it: that goes through CoreSimulatorService, which
  could block on the same volume and stall every simulator. After the reboot it works again as is.
- Worktrees get the guard once they merge main; older checkouts still fail when they land on slot 1.
- `ios-ui-test-split.sh` counts a stuck slot as free, so it may start one shard more than there are usable slots;
  that shard waits for the next slot to free up (correct, a little slower).

### Hung ps (2026-11-26)

Symptom: every repo test script hung for hours with an empty log; three runs sat 4-5 h at 0% CPU. Cause: a full-table
`ps -axo …` (then in `_lock.sh --slots` and `_fsevents-shim.sh`, before every build, to check fseventsd) hung in state
`U` itself, and nothing can kill or `alarm` a `U` process. `pgrep -x <name>`, `pgrep -P <pid>` and per-pid
`ps -o … -p <pid>` kept working.
- Rule for scripts: no full-table `ps`. Use the helpers in `scripts/_proc.sh` (bash 3.2): `bounded <secs> <cmd>` runs
  a call in the background and abandons it after `<secs>` (exit 124) instead of waiting on it; `proc_tree`,
  `tree_cpu` (`ps -S`: exited children count), `fseventsd_hung` (`pgrep -x` + per-pid `ps`), `stall_guard`.
  `LA_CARTE_FSEVENTS_SHIM=0/1` still overrides the fseventsd check.
- Stage lines: `ios-build.sh`, `ios-test.sh`, `ios-ui-test.sh` and `e2e.sh` print `▶ <time> <step>` on stderr at each
  step, and `⏳ still waiting at: <step> (N min)` after 2 min at the same step (`STAGE_WARN_SECS`), then every 10 min.
  A long but healthy test step also prints it; a hang now shows *where* in the log.

### Stuck runs: pool stall guard + `scripts/unstick.sh` (2026-11-26)

- Pool stall guard (local only): `_sim-pool.sh` runs the command (`test-without-building`, or ios-test.sh's build +
  test) under `stall_guard`: if its whole process tree used < `POOL_STALL_CPU` s (1) of CPU for `POOL_STALL_MIN` min
  (15; `0` = off), the tree is killed, the slot freed, exit 124. It counts xcodebuild's tree, not the simulator's
  processes: a test bundle that keeps xcodebuild silent and idle for 15 min would be killed (none locally today; on
  CI the guard is off). Set `POOL_STALL_MIN=0` for such a run.
- Both guards (pool and build slots) run the command through `guarded` (`_proc.sh`): its output reaches the caller
  through relays that are cut once the command is gone, so a leftover the kill can't reach (state `U`, or reparented)
  no longer holds the caller's `| grep` open. Before (2026-11-26): a unit run killed at 15 min sat "still waiting"
  until its leftover died at 72 min. A stalled pool run (124) also skips the device trim (no `simctl` on a suspect
  device). The test scripts never exit 0 without proof that tests ran (`docs/testing.md`, exit codes).
- `scripts/unstick.sh [--dry-run]`: the hourly watchdog (cron in the manager session runs
  `cd <repo> && scripts/unstick.sh`). Finds la-carte runs (`xcodebuild`, `xctest`, `lockf`, our scripts, `*-Runner`,
  only when args or cwd mention `la-carte`/`LaCarte`: other projects are never touched), samples each process tree
  twice 60 s apart, and kills (TERM, KILL 5 s later) trees older than 15 min that gained < 1 s CPU. A lock waiter
  (queued `lockf`, slot/pool poller) only counts as stuck when every holder of that lock is. Survivors are reported
  "unkillable, needs reboot" and remembered in `/tmp/la-carte-locks/unstick.unkillable`, so later runs don't signal
  them again. Also reports fseventsd / filecoordinationd / Xcode in `U` in both samples and SimAudioProcessorService
  with a stuck audio-plist read, and prints `reboot needed: yes/no`. Output: 5 lines; ~70 s; gives up after 200 s;
  always exits 0; no sudo, simctl or `~/Library`. Knobs for testing: `UNSTICK_WINDOW`, `UNSTICK_MIN_AGE`.

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
