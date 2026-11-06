# CI/CD

How this project gets from a pull request to a production Databricks catalog,
what runs, what it is allowed to touch, and how to fix it when it breaks.

Related: [DEPLOYMENT.md](DEPLOYMENT.md) (first-time setup, bundle, rollback) ·
[RUNBOOK.md](RUNBOOK.md) (daily operations) · [SECURITY.md](SECURITY.md)
(secrets and rotation).

---

## 1. Overview

```
   developer fork of the repo
            │  push branch, open PR
            ▼
 ┌──────────────────────────────────────────────┐
 │  dbt CI   (.github/workflows/dbt_ci.yml)     │
 │  trigger : pull_request → main               │
 │  target  : dev     catalog `dbt`             │
 │  env     : none (repository secrets only)    │
 │  checks  : deps → parse → debug → build      │
 │            + quality gate + artifacts        │
 └──────────────────────────────────────────────┘
            │  approved & merged to main
            ▼
 ┌──────────────────────────────────────────────┐
 │  dbt Deploy (.github/workflows/dbt_deploy.yml)│
 │  trigger : push → main  |  workflow_dispatch │
 │  target  : prod    catalog `dbt_prod`        │
 │  env     : GitHub environment `production`   │  ◄── required reviewers
 │  checks  : deps → debug → build              │
 │            + quality gate + artifacts        │
 └──────────────────────────────────────────────┘
            │
            ▼
   dbt_prod.bronze / silver / gold / snapshots / observability
```

Five principles:

1. **PRs can only write to `dev`.** There is no path from a pull request to
   `dbt_prod` - the prod job is a different workflow with a different trigger.
2. **Prod is a gated environment**, not a branch. Merging to `main` starts the
   deploy; `environment: production` makes it wait for approval when reviewers
   are configured.
3. **Toolchain is pinned.** dbt Fusion `2.0.11` and major-pinned Actions, so a
   `latest` release cannot break a run overnight.
4. **Failures are explained, not implied.** A credential precheck runs before
   dbt, and a quality gate runs after it, both emitting `::error` annotations
   with a link into this document.
5. **Every run leaves evidence.** `manifest.json`, `run_results.json`,
   `catalog.json` and `logs/` are uploaded as artifacts, on success and on
   failure.

## 2. Workflows at a glance

| | `dbt CI` | `dbt Deploy` |
|---|---|---|
| File | `.github/workflows/dbt_ci.yml` | `.github/workflows/dbt_deploy.yml` |
| Triggers | `pull_request` → `main`, `workflow_dispatch` | `push` → `main`, `workflow_dispatch` |
| Target | `dev` (catalog `dbt`) | `prod` (catalog `dbt_prod`) |
| Environment | none | `production` |
| Concurrency | `dbt-ci-<pr number>`, cancels superseded runs | `dbt-deploy-prod`, **never** cancels |
| Check name | `dev build (PR)` | `prod deploy` |
| Timeout | 45 min | 60 min |
| Permissions | `contents: read` | `contents: read` |

Both jobs share one composite action, `.github/actions/setup-dbt`, which owns
credential preflight and the pinned dbt install.

## 3. What runs

### 3.1 On a pull request

| Step | Command | Why |
|---|---|---|
| Preflight | (composite) | Fails in <1s if any `DATABRICKS_*` secret is empty |
| Install | `install.sh --version 2.0.11` | Pinned CLI, asserted by version check |
| deps | `dbt deps --profiles-dir .` | No-op today (no `packages.yml`) but future-proof |
| parse | `dbt parse --target dev` | YAML, `ref()` graph, macros - fails fast, no warehouse |
| debug | `dbt debug --target dev` | Connection, credentials, target catalog |
| build | `dbt build --target dev` | seed → snapshot → run → test in DAG order |
| gate | `jq` over `run_results.json` | Warning ceiling + job summary table |
| artifacts | `actions/upload-artifact` | Kept 14 days, uploaded even on failure |

### 3.2 On merge to `main`

Same sequence with `--target prod`, inside the `production` environment. The
deploy is serialised (`concurrency: dbt-deploy-prod`, `cancel-in-progress:
false`) so two merges can never interleave writes into `dbt_prod`.

### 3.3 Manual runs

`workflow_dispatch` runs `dbt CI` against dev, and `dbt Deploy` against prod
with an optional **`full_refresh`** input. Full refresh rebuilds incremental
models from scratch - snapshot history is append-only and is *not* reset.
Because the dispatch also goes through `environment: production`, the approval
step is the safety net for a manual prod run.

## 4. Composite action

`.github/actions/setup-dbt/action.yml`

| Input | Default | Purpose |
|---|---|---|
| `dbt-version` | `2.0.11` | Single place to bump the CLI |
| `databricks-host` / `http-path` / `token` | `""` | Passed from the caller's `secrets` context |

The action validates all three credentials before installing anything, so an
unconfigured repository fails with *"`DATABRICKS_TOKEN` is empty. Add it under
Settings → Secrets and variables → Actions"* instead of dbt's opaque
`Serde YAML Error: missing field token`.

Secrets are passed into the action as inputs and immediately bound to `env`
variables, so they are masked by Actions and never appear in logs.

## 5. Credentials

| Secret | Used by | Value |
|---|---|---|
| `DATABRICKS_HOST` | CI + CD | `https://dbc-f49d67a0-6a22.cloud.databricks.com` |
| `DATABRICKS_HTTP_PATH` | CI + CD | `/sql/1.0/warehouses/faced73bbff7e9f2` |
| `DATABRICKS_TOKEN` | CI + CD | Prefer a **service principal** PAT; a personal PAT works |

Set them at **Settings → Secrets and variables → Actions → Repository
secrets**. Moving them into the `production` *environment* instead (next
section) means PR jobs physically cannot read prod credentials - do that when
you set up the service principal.

Rules:

- Never put a token in `profiles.yml`, `dbt_project.yml`, `databricks.yml` or
  the workflow file. `profiles.yml` contains only `env_var()` references.
- **Fork PRs never receive secrets** (GitHub default, and we use
  `pull_request`, not `pull_request_target`). Contributors push branches to
  the origin repository so CI has credentials.
- Rotation procedure: [SECURITY.md](SECURITY.md).

## 6. Environments and approvals

The deploy job declares:

```yaml
environment: production
```

Until that environment has **required reviewers**, every merge to `main` starts
a prod build immediately. To arm the gate:

1. **Settings → Environments → New environment** (name: `production`) - it is
   already created by the first deploy run.
2. Under **Deployment protection rules** tick **Required reviewers** and add
   the four engineers.
3. Optional: **Wait timer** (e.g. 5 minutes) so a deploy can be cancelled
   after the fact.
4. Optional: scope the `DATABRICKS_*` secrets to this environment.

Then a merge shows *Waiting* until someone clicks **Approve**. See the
[GitHub environments docs](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

## 7. Quality gate

Both workflows run this after `dbt build`:

| Condition | Result |
|---|---|
| any result with status `error` or `fail` | **fail** (redundant with dbt's exit code, keeps the reason in the annotation) |
| warnings **greater than** `EXPECTED_WARNINGS` (5) | **fail** |
| warnings **fewer than** 5 | pass, with an annotation asking you to lower the baseline |
| warnings exactly 5 | pass |

Baseline run (`dbt build --target dev`, 98 results):

```
27 success   (26 models + 1 snapshot)
66 pass      (tests)
 5 warn      (tests - expected, documented below)
```

The five accepted warnings are listed in
[DATA_QUALITY.md](DATA_QUALITY.md); they are known data issues, not bugs:

| # | Test |
|---|---|
| 1 | `accepted_values_slv_orders_order_status__...` |
| 2 | `assert_scd2_no_future_versions` |
| 3 | `relationships_fct_payments_order_id__...` |
| 4 | `relationships_fct_returns_order_item_id__...` |
| 5 | `relationships_fct_sales_product_id__...` |

Changing the ceiling means editing `EXPECTED_WARNINGS` in **both**
`.github/workflows/dbt_ci.yml` and `.github/workflows/dbt_deploy.yml` in the
same PR as the warning - the change is then visible in review. We deliberately
do **not** use `--warn-error`: a new warning must be a conscious, reviewable
decision rather than an accidental red build.

## 8. Artifacts

| Artifact | Contents | Retention |
|---|---|---|
| `dbt-artifacts-dev-<run id>` | `manifest.json`, `run_results.json`, `catalog.json`, `logs/` | 14 days |
| `dbt-artifacts-prod-<run id>` | same | 14 days |

Uploaded with `if: always()`, so failures keep their evidence. Download from
the run page or:

```bash
gh run download <run-id> -n dbt-artifacts-dev-<run-id>
```

`manifest.json` is also what future slim CI (`--defer --state`) will compare
against, so keep it.

## 9. Version pinning

| Component | Pinned to | Where |
|---|---|---|
| dbt Fusion | `2.0.11` | `dbt-version` default in `.github/actions/setup-dbt/action.yml` |
| `actions/checkout` | `@v7` | both workflows |
| `actions/upload-artifact` | `@v7` | both workflows |
| Runner | `ubuntu-latest` | both workflows |

To bump dbt:

1. Edit the default `dbt-version` in the composite action (one place).
2. Run a PR - the CI job asserts the installed version matches.
3. Update the engine row in `README.md`.

Your local CLI should match CI. Check with `dbt --version`; if it reports a
different version, reinstall with the same pinned installer before trusting a
local result. Divergent local/CI versions are the classic "works on my
machine" source.

Pin the three Actions to full commit SHAs when you enable Dependabot for
actions (roadmap, section 14).

## 10. Reproducing CI locally

| CI step | Local equivalent |
|---|---|
| credential preflight | `echo $env:DATABRICKS_TOKEN` (never paste it) |
| deps | `dbt deps --profiles-dir .` |
| parse | `dbt parse --profiles-dir . --target dev` |
| debug | `dbt debug --profiles-dir . --target dev` |
| build | `dbt build --profiles-dir . --target dev` |
| quality gate | counts printed in the `Summary:` line of the dbt output |
| artifacts | `target/` and `logs/` after any local run |

Prod equivalent: `dbt build --profiles-dir . --target prod` - do that only via
the workflow, not from a laptop.

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Serde YAML Error: missing field token` / `dbt1011 AuthenticationFailed` | A `DATABRICKS_*` secret is missing or empty, so `env_var()` renders blank | Add the secret ([§5](#5-credentials)); the preflight step now names it before dbt runs |
| Steps show **`0s`** | Either the command really finishes in <1s (`dbt --version`, `dbt deps` with no `packages.yml`) or the step was **skipped** because an earlier step failed | Look at the first red step; a `0s` `dbt build` always means "skipped" |
| `dbt build` never ran | Preceding `dbt debug`/`dbt parse` failed, or a newer push to the same PR cancelled the run (`concurrency`) | Fix the failing step, or re-run from the run page |
| Run sits at **Waiting** | `production` environment requires a reviewer - this is the gate working | Someone with approval rights clicks **Approve** |
| `Catalog 'dbt_prod' does not exist` | Prod catalog never created | [DEPLOYMENT.md §3.1](DEPLOYMENT.md#31-create-catalogs) |
| `Warning ceiling exceeded` | A new test warns, or a data issue regressed | Fix it, or raise `EXPECTED_WARNINGS` in both workflows in the same PR ([§7](#7-quality-gate)) |
| PR fails at preflight, repo works for you | Fork PR - GitHub withholds secrets | Push the branch to the origin repo instead of a fork |
| CI green, prod fails | Targets differ only by catalog, so this means an environment/permission problem | Check `dbt debug --target prod`, catalog grants, warehouse availability |
| Deploy cancelled halfway | Never by this workflow (`cancel-in-progress: false`); only a manual cancel or a runner outage | Re-run the job; dbt is idempotent, the build resumes cleanly |

## 12. Required GitHub settings

One-time configuration, in order:

1. **Secrets**: three repository secrets (§5).
2. **Environment** `production` with required reviewers (§6) - *without this,
   merges deploy to prod with no click*.
3. **Ruleset on `main`** (Settings → Rules → Rulesets → new branch ruleset):
   - Require a pull request before merging, 1 approval (2 for snapshots,
     macros, `profiles.yml`, `.github/`)
   - Dismiss stale approvals on new commits; require conversation resolution
   - Require status check **`dev build (PR)`**
   - Block force pushes and deletions; require linear history
4. **Actions → General**: allow actions used here
   (`actions/checkout`, `actions/upload-artifact`, and the local
   `.github/actions/*`).

## 13. Promotion and rollback

- Promotion checklist: [DEPLOYMENT.md §7](DEPLOYMENT.md#7-release-checklist).
- Rollback: [DEPLOYMENT.md §8](DEPLOYMENT.md#8-rollback) - dbt is declarative,
  so rollback is a revert plus a rebuild, not a restore.
- Incident steps: [RUNBOOK.md §6](RUNBOOK.md#6-recovery-scenarios).

Prod and dev are separate catalogs, so a failed prod build can never corrupt
dev, and a rejected PR can never reach prod.

## 14. Roadmap

Ordered by value for a four-person team:

1. **Service principal + OIDC** instead of a long-lived PAT, with the token
   scoped to the `production` environment only.
2. **Slim CI** on PRs: `dbt build --select state:modified+ --defer --state
   <manifest>` using the uploaded prod `manifest.json` - faster feedback once
   the project grows past ~50 models.
3. **Environment-scoped secrets** (move the three secrets into
   `production`).
4. **SHA-pinned actions + Dependabot** for `github-actions`.
5. **Branch ruleset + CODEOWNERS** (§12 item 3) - currently unenforced.
6. **Scheduled freshness check** if the raw volume ever becomes live data
   instead of a static file drop.
