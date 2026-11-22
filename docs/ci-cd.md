# CI/CD: from a push to production

Owner: `cicd-lead` agent. Workflows: `.github/workflows/ci.yml` (every push/PR/nightly) and `ui-only.yml` (manual: selected UI tests, below). Signing and Ad Hoc builds
(`adhoc.yml`) belong to `release-engineer` (see `release.md`). The API server setup is in `deploy.md`.

## Pipeline map

```
pull_request ──┬─ API (ruff + pytest)          ubuntu   ~1 min
               ├─ API (docker build + /health) ubuntu   ~1 min
               ├─ iOS unit tests               macos-26
               └─ iOS UI smoke (light, 9 tests) macos-26: simulator boots in the background while the app
                                                builds, then tests the build      → PR feedback ≈ slowest job

push to main ──┬─ API ──────┐
               ├─ API image ┴─► Deploy API (Dokploy) → wait → scripts/api-live-check.sh   ~5 min after push
               ├─ iOS unit tests
               └─ iOS UI build (once: build-for-testing → artifact `ui-products`)
                    ├─ iOS UI, 4 shards in parallel (light + dark), no build: download, boot, test
                    │    deck-settings-study │ setup-report-launch │ theme-ratings │ rest
                    └─ iOS E2E (live API), same build

nightly 03:00 UTC (schedule) and manual run (workflow_dispatch): same jobs as a push to main.
The deploy job runs only on push and on a manual run of main.
```

Concurrency: on a PR, a new push cancels the old run. On `main`, runs queue instead of cancelling, so a deploy
is never cut off half-way. The deploy job has its own `deploy-api` group, so deploys never overlap.
The free plan runs at most 5 macOS jobs at once: unit tests + the UI build start together; the 4 shards and E2E
start when the build ends (unit tests are done by then).

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
  that ran no test at all (`TESTS: none run`): it waits 30 s and retries once. A failing test is never retried.

Screenshots: each UI job uploads its own artifact (`screenshots-smoke`, `screenshots-<shard>`, `screenshots-e2e`).

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
| API deploy | `API (ruff + pytest)` and `API (docker build)` green on that exact commit, which is also the head of `main` | iOS jobs (the app ships separately, via `adhoc.yml`) |
| PR merge | every job of the PR run (unit + API + smoke) | the full UI suite (it runs on `main` and nightly) |

**Smoke set** (in `ci.yml`, job `ios-ui-smoke`): core study, deck, settings/setup and refresh flows in light
mode. `qa-validator` owns the list. Keep it under about 10 tests and pick tests that are not flaky.

**Shards** (job `ios-ui`, matrix): whole `XCTestCase` classes, balanced on measured durations (local
`ui-test-durations.tsv`; CI is ≈ 1.6–1.9× slower). The `rest` shard runs `-only-testing:LaCarteUITests` minus
every class the other shards name, so a new class runs there without any change. Move it to a named shard (and
add it to `rest`'s skips) when `rest` gets too long. `MarketingUITests` (demo frames) never runs on CI. The
`*_liveAPI` tests skip in the mock shards and run in E2E.

## API deploy

Dokploy's auto-deploy is **off** for the API compose service. The job `deploy-api` runs
`ci/deploy-api.sh`:

1. If `main` has moved on since this commit, it skips: Dokploy builds the head of `main`, and the newer run
   deploys it.
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

Retry a failed deploy: *Actions → CI → Run workflow* on `main` (it re-runs the API jobs, then deploys).

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
| API live after push to main | ~5 min, only after API tests pass | unchanged |

Before: every UI job built the app itself at `-jobs 1`. Test steps have timeouts (shard 40, E2E 30, smoke 20 min;
unit and build jobs 30): a hung test held a shard for over 50 min (and main's run queue behind it).
Next levers: the artifact download (2.3 min for 224 MB), a 5th shard once the unit job is shorter (free-plan limit
of 5 macOS jobs), caching SwiftPM/DerivedData for the PR build.
