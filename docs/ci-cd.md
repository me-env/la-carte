# CI/CD: from a push to production

Owner: `cicd-lead` agent. One workflow, `.github/workflows/ci.yml`. Signing and Ad Hoc builds
(`adhoc.yml`) belong to `release-engineer` (see `release.md`). The API server setup is in `deploy.md`.

## Pipeline map

```
pull_request ──┬─ API (ruff + pytest)          ubuntu   ~1 min
               ├─ API (docker build + /health) ubuntu   ~1 min
               ├─ iOS unit tests               macos-26 ~4 min
               └─ iOS UI smoke (light, 9 tests) macos-26 ~10 min   → PR feedback ≈ 10 min

push to main ──┬─ API ──────┐
               ├─ API image ┴─► Deploy API (Dokploy) → wait → scripts/api-live-check.sh   ~5 min after push
               ├─ iOS unit tests ──► iOS E2E (live API, its own job)                    ~4 + ~10 min
               └─ iOS UI, 4 shards in parallel (light + dark):                           ~18 min
                    theme │ deck │ study │ settings + setup + refresh + design system

nightly 03:00 UTC (schedule) and manual run (workflow_dispatch): same jobs as a push to main.
The deploy job runs only on push and on a manual run of main.
```

Concurrency: on a PR, a new push cancels the old run. On `main`, runs queue instead of cancelling, so a deploy
is never cut off half-way. The deploy job has its own `deploy-api` group, so deploys never overlap.
The free plan runs at most 5 macOS jobs at once: the 4 shards plus unit tests start together, and E2E starts
when unit tests end (it runs even if they fail).

Screenshots: each UI job uploads its own artifact (`screenshots-smoke`, `screenshots-theme`,
`screenshots-deck`, `screenshots-study`, `screenshots-settings-refresh-misc`, `screenshots-e2e`).

## Gates

| What | Gated by | Not gated by |
|---|---|---|
| API deploy | `API (ruff + pytest)` and `API (docker build)` green on that exact commit, which is also the head of `main` | iOS jobs (the app ships separately, via `adhoc.yml`) |
| PR merge | every job of the PR run (unit + API + smoke) | the full UI suite (it runs on `main` and nightly) |

**Smoke set** (in `ci.yml`, job `ios-ui-smoke`): core study, deck, settings/setup and refresh flows in light
mode. `qa-validator` owns the list. Keep it under about 10 tests and pick tests that are not flaky.

**Shards** (job `ios-ui`, matrix): one entry per `XCTestCase` class, balanced on measured durations. A new UI
test class must be added to a shard, or it never runs on CI. `SetupUITests.swift` is an extension of
`SettingsUITests`, so it runs in that shard. The `*_liveAPI` tests skip in the mock shards and run in E2E.

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

| Run | Before | Target (to be measured on the first runs) |
|---|---|---|
| PR | ~50 min (full UI suite in one job) | ~10 min (slowest job: UI smoke) |
| push to main, full UI | ~50 min, E2E skipped when UI failed | ~18 min (slowest shard: theme, ~5 min build + ~12 min tests); E2E always runs |
| API live after push to main | ~3 min, untested (Dokploy auto-deploy on every push) | ~5 min, only after API tests pass |

Each shard builds the app itself (about 5 min). Next step if needed: one `build-for-testing` job plus
`test-without-building` shards (`docs/tooling.md` P2), which saves about 4 min per shard.
