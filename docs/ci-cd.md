# CI/CD: from a push to production

Owner: `cicd-lead` agent. Workflows: `.github/workflows/ci.yml` (every push/PR/nightly) and `ui-only.yml` (manual: selected UI tests, below). Signing and Ad Hoc builds
(`adhoc.yml`) belong to `release-engineer` (see `release.md`). The API server setup is in `deploy.md`.

## Pipeline map

Every run starts with `What changed` (`ci/changes.sh`, ≈ 10 s), which decides which of the jobs below run
(see *Path filters*).

```
pull_request ──┬─ API (ruff + pytest)          ubuntu   ~1 min
               ├─ API (docker compose + /me)   ubuntu   ~30 s
               ├─ iOS unit tests               macos-26
               └─ iOS UI smoke (light, 9 tests) macos-26: simulator boots in the background while the app
                                                builds, then tests the build      → PR feedback ≈ slowest job

push to main ──┬─ API ───────────────────────────────┐
               ├─ API image ─────────────────────────┤
               ├─ iOS unit tests                     ├─► Deploy API (Dokploy) → wait → scripts/api-live-check.sh
               └─ iOS UI build (once: build-for-testing → artifact `ui-products`)
                    ├─ iOS E2E (live API), same build ┘    ≈ 19 min after the run starts
                    └─ iOS UI, 5 shards in parallel (light + dark), no build: download, boot, test
                         deck-settings-study │ setup-widget │ theme-ratings-report │ notes-logo-milestones │ rest

nightly 03:00 UTC (schedule) and manual run (workflow_dispatch): same jobs as a push to main.
The deploy job runs only on push and on a manual run of main.
```

Concurrency: on a PR, a new push cancels the old run. On `main`, a running run is never cancelled (nor its
deploy), but GitHub keeps only **one pending run per group**: each new push replaces the waiting one. With several
pushes an hour and a 45 min full run, most commits get no run of their own. That is by design: the waiting run is
always the newest commit, and its `What changed` diff starts at the last green run of `main`, so it tests the
changes of every commit in between. One run at a time on `main` also means deploys run one at a time and in commit
order (the deploy job also has its own `deploy-api` group). A run per commit is not possible: the free plan has
5 macOS jobs and a full run uses 6.
The free plan runs at most 5 macOS jobs at once: unit tests + the UI build start together; when the build ends,
E2E and 3 shards start (unit tests still run, ≈ 22 min since `ScreenColorTests` takes ≈ 14 min on CI); the last 2
shards start as soon as the unit job and E2E end.
A `pending` run on `main` is waiting for the running one (a full run is ≈ 45–55 min), not stuck. GitHub can also
cancel a macOS job it cannot place ("The job was not acquired by Runner of type hosted", run 45692283093): the run
ends red/cancelled, the next run retests it. While `main` has no green run, `ci/changes.sh` diffs against the last
green one, so even API-only pushes run the full iOS suite: fix red `main` first.

Speed settings (measured 2026-11-22, run 45032373007):
- `BUILD_SLOTS: 1` (workflow env): `scripts/_ios-env.sh` splits CPUs over 2 build slots by default, which gave
  the 3-CPU runner `-jobs 1` (app build ≈ 15 min per job). One slot = `-jobs 3`.
- Build once: `ci/build-ui-tests.sh` runs the same `build-for-testing` as `scripts/ios-ui-test.sh`; the test jobs
  get the `.xctestproducts` as a tar artifact (a zip artifact drops executable bits) and run
  `UI_TEST_PRODUCTS=<dir> scripts/ios-ui-test.sh …`, which then skips its build.
- `ci/boot-simulator.sh --start` / `--wait`: the boot (CoreSimulator start ≈ 1 min, data migration ≈ 2 min,
  appearance switch, one system-app launch so SpringBoard is not "Busy") overlaps the build or the download.
  It prints how long each phase took. It also marks the keyboard's "slide to type" intro as shown (in
  `com.apple.keyboard.preferences`, which iOS 26+ reads, and `com.apple.Preferences`): that screen covered the
  first keyboard on CI and swallowed typing.
- XCTest's cold-launch timeout ("Timed out while launching application via Xcode") is retried once by the
  UI test helpers (`launch` in `ios/LaCarteUITests/Support.swift`). A pre-test warm-up launch (`--warm-app`,
  removed) did not prevent it (run 45052223117: `LogoUITests/testLogo_gallery` still timed out) and cost
  0.6–1.4 min per job.
- A runner refused by the simulator ("Application failed preflight checks … Busy") is retried once inside
  `scripts/ios-ui-test.sh` (`scripts/_ui-retry.sh`, `CI infra` warning); refused twice prints
  `TESTS: infra failure (…)` and fails. `ci/ui-test.sh` wraps every UI run and only covers prebuilt products
  that ran no test at all (`TESTS: none run`): it waits 30 s and retries once. A failing test is retried once only in
  the full-suite shards (see *Flaky tests*); smoke, E2E and local runs never retry.

Screenshots: each UI job uploads its own artifact (`screenshots-smoke`, `screenshots-<shard>`, `screenshots-e2e`). Just
before the upload, `ci/artifact-safe-names.sh qa/screenshots` replaces the characters `upload-artifact` rejects
(`" : < > | * ?`, CR, LF) with `_`: one such name (an XCUITest attachment named
`Debug description for "NotificationShortLookView" …`) failed the whole upload of a shard in run 45925206158.

## Path filters

`ci/changes.sh` sorts the changed files (a PR: against its base; a push to `main`: against the newest `main` commit
with a green CI run; nightly and manual runs: everything):

| Changed | Runs on a PR | Runs on `main` |
|---|---|---|
| only `docs/`, `qa/`, `marketing/`, `.claude/`, `*.md`, `LICENSE`, `.gitignore`, `adhoc.yml`, `ui-only.yml` | `What changed` only | `What changed` only (no deploy) |
| also `api/`, `docker-compose.yml`, `scripts/api-*` | API + API image | API + API image, UI build + E2E, then deploy |
| anything else (`ios/`, other `scripts/`, `ci/`, `ci.yml`, …) | everything (unit + API + smoke) | everything |

Unknown paths run everything, so a new top-level file is tested until it is added to a list. A red or cancelled
run never becomes a base, so its changes are tested again by the next run.

## Run one test class on CI

For a test that fails only on CI: *Actions → UI tests (selected) → Run workflow*, or
```bash
gh workflow run ui-only.yml -R me-env/la-carte -f tests="LaCarteUITests/DeckUITests"   # --ref <branch> for a branch
gh run watch -R me-env/la-carte "$(gh run list -R me-env/la-carte -w ui-only.yml -L 1 --json databaseId -q '.[0].databaseId')"
gh run download -R me-env/la-carte <run id> -n screenshots-selected -D /tmp/ci-selected
```
`tests` is space-separated `-only-testing` targets (`LaCarteUITests/<Class>` or `LaCarteUITests/<Class>/<test>`).
One macOS job (`.github/workflows/ui-only.yml`): the same build (`ci/build-ui-tests.sh`), background boot as
`ci.yml`, then only those tests. With `record` (default on) the artifact `screenshots-selected` keeps
every test's recording (`recordings/`) and the runner output (`logs/`). No deploy, no other jobs.

## Gates

| What | Gated by | Not gated by |
|---|---|---|
| API deploy | `API (ruff + pytest)`, `API (docker compose)` and `iOS E2E (live API)` green on that exact commit, which is also the head of `main`; only when the API changed since the last green run | iOS unit tests and UI shards (the app ships separately, via `adhoc.yml`) |
| PR merge | every job of the PR run that its changes need (unit + API + smoke) | the full UI suite (it runs on `main` and nightly) |

**Smoke set** (in `ci.yml`, job `ios-ui-smoke`): core study, deck, settings/setup and refresh flows in light
mode. `qa-validator` owns the list. Keep it under about 10 tests and pick tests that are not flaky.

**Shards** (job `ios-ui`, matrix): whole `XCTestCase` classes, balanced on measured CI durations (sum of the
`Test Case … (N seconds)` lines per class in the shard logs). The `rest` shard runs `-only-testing:LaCarteUITests`
minus every class the other shards name, so a new class runs there without any change. Move it to a named shard (and
add it to `rest`'s skips) when `rest` nears 30 min of tests: the step times out at 40 min. `MarketingUITests` (demo
frames) never runs on CI. The `*_liveAPI` tests skip in the mock shards and run in E2E.

| Shard | Classes (CI seconds, runs 45721818305 + 45811826958) | Tests |
|---|---|---|
| deck-settings-study | Deck 924, Settings 258, Refresh 144, Study 78, LaCarte 72, Launch 36 | ≈ 25 min |
| setup-widget | Widget 672, Setup 654, StudyLengths 234 | ≈ 26 min |
| theme-ratings-report | Ratings 642, Theme 498, Report 354 | ≈ 25 min |
| notes-logo-milestones | Notes 1000, StudyMilestones 228, Logo 185 | ≈ 24 min |
| rest | Activity ≈ 535, StudyEdit 384, StudyRevealLift (new, not yet measured) (+ any new class) | ≈ 17 min + new |

2026-11-25: `rest` had grown to Logo + Notes + StudyEdit + StudyLengths + StudyMilestones + Refresh + Widget
(≈ 48 min of tests) and hit the 40 min step timeout on every run since 2026-11-23 (runs 45137446390, 45165043450,
45398848333, 45608039397; `WidgetUITests`, 12 min on CI, never ran). Rebalanced to the table above.
2026-11-26: 029 added `ActivityUITests` (≈ 9 min, its timing test ≈ 8 min per attempt) to `rest`, and `NotesUITests` grew
to ≈ 17 min: `rest` hit the 40 min timeout again (run 45811826958; StudyEdit, StudyMilestones and StudyRevealLift
never ran). Notes, Logo and StudyMilestones moved to a 5th shard.

**Quarantine** (`-skip-testing` in the shard, `ci.yml`). A quarantined test still runs locally and in
`ui-only.yml`; the owner fixes it, then removes the skip.

| Test | Owner | Failure on CI | Fix |
|---|---|---|---|

None today. Released 2026-11-27: `DeckUITests/testDeck_addFromDeck` (the app re-requests Front focus until UIKit
really begins editing; spec 002 #6). Released 2026-11-26: `LogoUITests/testStudy_launchShowsFirstCardNoLogo` (one query per check;
limit 2.5 s when `CI` is set, which `scripts/ios-ui-test.sh` passes to the test runner as `TEST_RUNNER_CI`; 1.5 s locally).

**Flaky tests.** The full-suite shards run with `-retry-tests-on-failure -test-iterations 2`: a test that fails
then passes keeps the shard green, and `ci/ui-test.sh` prints a `Flaky UI test (passed on retry)` warning on the
run's summary page. Why: from 2026-11-23 to 25, every full run (≈ 120 tests) had 1–2 failures, each time a different
test, on the same or unrelated commits (Ratings, Report, StudyLengths, Deck, Logo): CI-load timing, not regressions,
and `main` never went green (so `ci/changes.sh` ran the full suite on every push). The owner (`qa-validator` for UI
tests) fixes any test that shows up in those warnings; one that fails both attempts turns the run red as before, and
a test that is red in 2 runs gets quarantined above.

Seen once or twice (not quarantined): `StudyLengthsUITests/testStudyLengths_scrollBarOnRevealOnly` failed once in 5 runs on the
same commit ("no scroll bar flash on revealing a long card"); fixed 2026-11-26: `barPoints` counts frames from the
start of a tap (not after it returns) over 2.5 s. `ReportUITests/testAsk_copiesCardText`
failed twice on 2026-11-23/24 (empty pasteboard), passed since. `ReportUITests/testReport_menuOpensAndCancels` failed
once (run 45706902438, "dialog still shown after Cancel"), passed in the 4 runs before. `RatingsUITests/testRatings_dragReviewFailureThenRetry` failed
once (rerun of 45706902438, '"study.front" Any missing').

**Stall guard** (`scripts/_lock.sh --slots`, dev-velocity's fix for a hung `fseventsd` on the Mac) is off on CI
(`CI` set → `STALL_MIN=0`), like the FSEvents shim. It counts only the CPU of the wrapped command's own process
tree, not the simulator's test processes, so in run 45811826958 it killed `scripts/ios-test.sh` 10 min into
`ScreenColorTests` (which prints nothing until it ends) and the unit job failed with exit 124 and "result bundle
Info.plist does not exist".

## API deploy

Dokploy's auto-deploy is **off** for the API compose service. The job `deploy-api` runs
`ci/deploy-api.sh`:

1. Dokploy builds the head of `main`, not a given commit. If `main` has moved on since this commit, it deploys
   only when the head has the same `api/` and `docker-compose.yml` (so the image is the tested one); otherwise it
   skips and the newer run deploys. Without this, busy days (a push every few minutes, deploy ≈ 18 min into the
   run) never deployed (run 45071709294 skipped).
2. If the live `/health` build hash already equals this commit's and `api/` + `docker-compose.yml` did not
   change since the previous push, it skips (nothing to deploy).
3. `POST $DOKPLOY_URL/api/compose.deploy` with header `x-api-key` and `{"composeId", "title": "CI <sha7>"}`.
   The call only queues the deploy.
4. It polls `GET /api/deployment.allByCompose?composeId=…` until the deployment with that title is `done`
   (fails on `error`/`cancelled`, or after 15 min).
5. It runs `scripts/api-live-check.sh` against the `LA_CARTE_LIVE_URL` secret (never printed) until the public `/health` reports this commit's
   build (fails after 1 min).

Why the API and not the per-service webhook: Dokploy's webhook (`/api/deploy/compose/<token>`) refuses
requests when auto-deploy is off and expects a git-provider push payload.

Retry a failed deploy: *Actions → CI → Run workflow* on `main` (it runs everything, then deploys after E2E).

### One-time setup (manager)

1. **Dokploy** → your project → the API compose service → *General*: turn **Auto Deploy off**. Keep the
   provider on branch `main`.
2. **Dokploy** → *Settings → Profile → API/CLI*: generate an API key. Dokploy keys carry the creating
   user's permissions (no per-service scope). Prefer a member that can only deploy this project.
3. **GitHub** → repo *Settings → Environments* → **New environment `api-prod`**. Under *Deployment branches
   and tags*, choose *Selected branches* → `main`. Then add:
   ```bash
   gh secret   set DOKPLOY_API_KEY    --env api-prod                                  # paste the key
   gh variable set DOKPLOY_URL        --env api-prod --body 'https://<your Dokploy host>'
   gh variable set DOKPLOY_COMPOSE_ID --env api-prod --body '<your compose id>'
   gh secret   set LA_CARTE_LIVE_URL  --env api-prod --body 'https://<your API host>'   # secret: masked in logs
   ```
   Without these values the job prints a notice and skips (forks).
4. **Before the accounts API (spec 030a, branch `accounts`) merges:** set `LA_CARTE_OWNER_EMAIL` in the
   Dokploy compose service's *Environment* (the owner's Apple or Google email; see `docs/deploy.md`). With
   `LA_CARTE_API_TOKEN` set and no owner email the API refuses to start, and on a deck with data migration 030
   refuses to run, so the deploy job fails at step 5 and prod stays down until it is set. `/health` stays public
   (no bearer), so `scripts/api-live-check.sh` and the deploy check need no token. CI's image check passes
   `ci@example.com`. Also set `LA_CARTE_DB_KEY` (spec 032a: with `LA_CARTE_PUBLIC_URL` set the API refuses to
   start without it) and, for Google sign-in, `LA_CARTE_GOOGLE_CLIENT_ID` + `_SECRET` (without them prod
   starts with Google sign-in off). The full list is in `docs/deploy.md`; a setting reaches the container
   only if `docker-compose.yml` lists it. CI's image check boots the API through `docker-compose.yml` with
   throwaway values (https public URL, random DB key, owner email, token) and calls `/health` and `/me`, so a
   compose mistake fails CI, not the deploy. A setting it does not pass gets the compose file's default.

## Rollback

One step, through the same gate: `git revert <bad sha> && git push`. CI tests the revert, then deploys it
(about 5 min). Dokploy has no documented "redeploy a previous deployment" for compose services, and with
auto-deploy off it always builds the head of `main`. The revert is the rollback.

The deck itself lives in the `la-carte-data` volume, and deploys never touch it. Restoring data is covered
in `deploy.md` → Backups.

## Expected timings

| Run | Before (run 45032373007, 2026-11-22) | After (run 45037833157) |
|---|---|---|
| PR | unit 13 min; smoke ≈ 15 min build + boot + tests | unit 9.3–10.5 min; smoke ≈ 7 min build (boot overlapped) + tests: to be measured on the next PR |
| push to main, iOS | 43 min (4 shards of 27–32 min: boot 3–4.5, build ≈ 15, tests 8–10; E2E after unit, 30 min). 8 classes (≈ 50 tests) never ran | UI build 6.8 min once; shards (download 2.3 + boot wait ≈ 1–3 + tests 16–20) 21–27 min, E2E 13.9 min (done at +21); iOS done at ≈ +38 min with all classes (≈ 95 mock tests instead of 45) |
| API live after push to main | ~5 min, only after API tests pass | ≈ 19 min after the run starts (run 45071709294): also gated on E2E (2026-11-22, path filters) |

Path filters (2026-11-22): before, 15 of the 18 pushes to `main` between 18:06 and 20:42 UTC were cancelled while
waiting, and the last full run (45058790864) waited 40 min for the slot, then took 45 min.
Of the 136 commits on 2026-11-22, 36 were docs-only (now ≈ 1 min), 7 API-only (≈ 19 min: UI build + E2E, no
shards or unit) and 93 touched the app (full run). A waiting run covers the union since the last green run, so
most runs stay full: the filters mainly stop docs pushes from holding the slot; the real cost is the 45 min full run.

Before: every UI job built the app itself at `-jobs 1`. Test steps have timeouts (shard 40, E2E 30, smoke 20 min;
unit and build jobs 30): a hung test held a shard for over 50 min (and main's run queue behind it).
Next levers: the unit job (≈ 22 min, ≈ 14 of them `ScreenColorTests`; it holds a macOS slot the 4th/5th shards wait
for), the artifact download (2.3 min for 224 MB), caching SwiftPM/DerivedData for the PR build.
