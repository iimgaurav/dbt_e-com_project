# Deployment

## 1. Environments

| | dev | prod |
|---|---|---|
| dbt target | `dev` | `prod` |
| Catalog | `dbt` | `dbt_prod` |
| Schemas | `bronze`, `silver`, `gold`, `snapshots` | same names, different catalog |
| Threads | 4 | 8 |
| Bundle target | `dev` (default) | `prod` (`mode: production`) |
| Job name | `sales_analytics_dbt_dev` | `sales_analytics_dbt_prod` |
| Schedule | none | 02:30 IST daily (paused on deploy) |

Isolation is by catalog, so a dev run can never overwrite a production table.
See `profiles.yml` and `databricks.yml`.

## 2. Prerequisites

- Databricks CLI ≥ 0.220, authenticated as profile `DEFAULT`
- dbt Fusion installed (`dbt --version`)
- Workspace access to the serverless SQL warehouse `faced73bbff7e9f2`
- Permission to create catalogs/schemas/volumes (or an admin to do step 3)

```powershell
databricks auth describe --profile DEFAULT
dbt --version
```

## 3. First-time setup

### 3.1 Create catalogs

The dev catalog `dbt` already exists. Create the production catalog **once**:

```sql
CREATE CATALOG IF NOT EXISTS dbt_prod;
```

> `databricks catalogs create` fails in this workspace with *"Please use the UI
> to create a catalog with Default Storage"*. Use the UI or `CREATE CATALOG` via
> a SQL warehouse.

### 3.2 Create schemas and the raw volume

```sql
CREATE SCHEMA IF NOT EXISTS dbt.raw;
CREATE SCHEMA IF NOT EXISTS dbt_prod.raw;

CREATE VOLUME IF NOT EXISTS dbt.raw.sales_analytics_raw;
CREATE VOLUME IF NOT EXISTS dbt_prod.raw.sales_analytics_raw;
```

Bronze/silver/gold schemas are created automatically by dbt on first run.

### 3.3 Upload the raw CSVs

```powershell
databricks fs cp .\sales_analytics_raw\orders_raw.csv `
  dbfs:/Volumes/dbt/raw/sales_analytics_raw/orders_raw.csv --profile DEFAULT
# repeat for order_items, customers, products, stores, payments, returns
```

> PowerShell rewrites `/Volumes/...` arguments to backslashes. Always use the
> `dbfs:/Volumes/...` form with `databricks fs cp`.

Verify:

```sql
LIST '/Volumes/dbt/raw/sales_analytics_raw';
```

### 3.4 Set the token

The project never stores the PAT. It reads `DATABRICKS_TOKEN` at runtime.

```powershell
$t = (Select-String -Path "$env:USERPROFILE\.databrickscfg" `
      -Pattern '^token\s*=\s*(.+)$').Matches[0].Groups[1].Value.Trim()
$env:DATABRICKS_TOKEN = $t
dbt debug --profiles-dir .
```

For CI, store it as the GitHub secret `DATABRICKS_TOKEN` (plus
`DATABRICKS_HOST` and `DATABRICKS_HTTP_PATH`). For the Databricks job, dbt
authenticates through the job's own identity — no PAT is embedded in the
bundle.

### 3.5 Validate the connection

```powershell
dbt debug --profiles-dir .
```

Expect `All checks passed!`.

## 4. Build and promote

### Dev

```powershell
.\scripts\build.ps1
# or
dbt build --profiles-dir . --target dev
```

### Prod

```powershell
$env:DBT_TARGET = "prod"
dbt build --profiles-dir . --target prod
```

Or with the helper: `.\scripts\build.ps1 -Target prod`.

Promotion is a **target switch only** — the same SQL, tests and macros run
against a different catalog. There is no separate prod branch requirement.

## 5. CI/CD (GitHub Actions)

Two workflows, plus one shared composite action
(`.github/actions/setup-dbt`: credential preflight → pinned dbt Fusion
install → version assertion):

| Workflow | Trigger | Target | Gate |
|---|---|---|---|
| `dbt CI` (`.github/workflows/dbt_ci.yml`) | `pull_request` → `main`, manual | `dev` (`dbt`) | required check `dev build (PR)` |
| `dbt Deploy` (`.github/workflows/dbt_deploy.yml`) | `push` → `main`, manual | `prod` (`dbt_prod`) | GitHub environment `production` |

Both run the same sequence:

1. Credential preflight (names any missing secret before dbt runs)
2. Install dbt Fusion `2.0.11` (pinned, version-asserted)
3. `dbt deps --profiles-dir .`
4. CI only: `dbt parse` (fast static validation)
5. `dbt debug --profiles-dir . --target <env>`
6. `dbt build --profiles-dir . --target <env>` (seed → snapshot → run → test)
7. Quality gate: fails on errors/fails or more than 5 warnings; writes a
   result table to the job summary
8. Upload `manifest.json`, `run_results.json`, `catalog.json`, `logs/`
   (14 days, uploaded even on failure)

Prod deploys are serialised (`concurrency: dbt-deploy-prod`,
`cancel-in-progress: false`) and never cancelled by a newer push. A manual
`workflow_dispatch` on `dbt Deploy` accepts a `full_refresh` input.

Required repository secrets:

| Secret | Value |
|---|---|
| `DATABRICKS_HOST` | `https://dbc-f49d67a0-6a22.cloud.databricks.com` |
| `DATABRICKS_HTTP_PATH` | `/sql/1.0/warehouses/faced73bbff7e9f2` |
| `DATABRICKS_TOKEN` | Service-principal PAT (recommended over a personal token) |

Full reference - environments and reviewers, branch ruleset, quality-gate
baselines, artifact handling, troubleshooting: **[CI_CD.md](CI_CD.md)**.

Hardening status:

| Hardening step | Status |
|---|---|
| Pin the Fusion installer to a specific version | **Done** - `2.0.11`, pinned in `.github/actions/setup-dbt` |
| GitHub Environment (`production`) with required reviewers | Environment exists; **required reviewers still to be added** |
| Use a service principal, not a personal PAT | Not yet - [CI_CD.md §14](CI_CD.md#14-roadmap) |
| `dbt build --select state:modified+` on PRs (slim CI) | Not yet - [CI_CD.md §14](CI_CD.md#14-roadmap) |

## 6. Databricks Asset Bundle

The bundle deploys the **job definition**, not the data.

```
databricks.yml            # bundle name, variables, dev/prod targets
resources/dbt_job.yml     # job: schedule, environment, dbt_task
```

Key settings in `resources/dbt_job.yml`:

- `environments: [{environment_key: default, spec: {client: "2"}}]` — serverless
  environment required by the dbt task
- `task.environment_key: default`
- `dbt_task.warehouse_id: ${var.warehouse_id}`
- `dbt_task.catalog: ${var.catalog}` (overridden per target)
- `max_concurrent_runs: 1` — prevents overlapping runs
- `pause_status: PAUSED` — safe by default

### Validate and deploy

```powershell
databricks bundle validate -t dev  --profile DEFAULT
databricks bundle validate -t prod --profile DEFAULT

.\scripts\deploy.ps1 -Target prod
# expands to:
#   databricks bundle validate -t prod --profile DEFAULT
#   databricks bundle deploy  -t prod --profile DEFAULT
```

Deployed location:

```
/Workspace/Users/<user>/.bundle/sales_analytics/<target>
```

### Run

```powershell
databricks bundle run sales_analytics_dbt -t prod --profile DEFAULT
```

### Unpause the schedule

Only after a successful manual prod run:

```powershell
databricks jobs update --json '{
  "job_id": <id>,
  "new_settings": {"schedule": {"pause_status": "UNPAUSED"}}
}' --profile DEFAULT
```

(Or toggle **Pause status** in the job UI.)

## 7. Release checklist

Before promoting to prod:

- [ ] `dbt build --target dev` is green (0 errors)
- [ ] Warning count is exactly 5 and matches [DATA_QUALITY.md](DATA_QUALITY.md)
- [ ] `databricks bundle validate -t dev` passes
- [ ] `databricks bundle validate -t prod` passes
- [ ] `dbt_prod` catalog and `dbt_prod.raw.sales_analytics_raw` volume exist
- [ ] Prod secrets are set in GitHub
- [ ] Row counts on dev are sane (see [DATA_DICTIONARY.md](DATA_DICTIONARY.md))
- [ ] Docs updated for any new model, column, or rule

After deploy:

- [ ] Manual prod run succeeds
- [ ] Verification queries pass (see [RUNBOOK.md](RUNBOOK.md#4-verification-queries))
- [ ] Schedule unpaused
- [ ] Failure email recipient confirmed

## 8. Rollback

dbt is declarative and idempotent, so rollback is a rebuild, not a restore:

| Scenario | Action |
|---|---|
| Bad model logic deployed | Revert the SQL, redeploy, `dbt build --select <model>+ --full-refresh` |
| Bad source file loaded | Replace the file, `dbt build --select tag:bronze+ --full-refresh` |
| Bad bundle deployed | `databricks bundle deploy -t prod` from the previous commit |
| Job keeps failing | Pause the schedule, fix, run manually, unpause |

Because prod and dev are separate catalogs, a failed prod build never affects
dev, and vice versa.

## 9. Cost and performance notes

- Bronze reads all seven CSVs on every full run. At the current ~6.7k rows this
  is negligible; at scale, migrate bronze to Auto Loader / streaming tables.
- Gold tables are small enough that full rebuilds are cheaper than incremental
  complexity. Revisit when any fact exceeds ~100M rows.
- The warehouse auto-stops; the job starts it on demand.
- `dim_customers_scd2` is a view — cheap at 315 rows, but at millions of
  versions consider materialising it with an incremental window.
