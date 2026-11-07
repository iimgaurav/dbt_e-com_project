# sales_analytics — production dbt project on Databricks

A medallion (bronze → silver → gold) analytics project for a retail sales
dataset, built with **dbt Fusion** on **Databricks Unity Catalog**. It ingests
raw CSVs from a UC volume, cleans and quarantines dirty records, maintains a
Type-2 customer dimension, and publishes a star schema for BI.

| | |
|---|---|
| dbt engine | dbt Fusion `2.0.0-preview.186` |
| Warehouse | Serverless SQL warehouse `faced73bbff7e9f2` |
| Workspace | `https://dbc-f49d67a0-6a22.cloud.databricks.com` |
| Raw volume | `/Volumes/dbt/raw/sales_analytics_raw` |
| Dev catalog | `dbt` (schemas `bronze`, `silver`, `gold`, `snapshots`) |
| Prod catalog | `dbt_prod` (must be created before first prod deploy) |
| Orchestration | Databricks Asset Bundle (`databricks.yml`) |
| Local scheduler | Flask + APScheduler dashboard (`scheduler/`) |
| CI/CD | GitHub Actions: `dbt CI` (PR → dev) + `dbt Deploy` (main → gated prod) |

## Current build status

```
dbt build --profiles-dir .
Processed: 4 hooks | 26 models | 71 tests | 1 snapshot
Summary:   102 total | 97 success | 5 warn
```

The 5 warnings are **expected** — they are data-quality signals on a
deliberately dirty practice dataset (see [docs/DATA_QUALITY.md](docs/DATA_QUALITY.md)).
There are no errors.

## Architecture at a glance

```
┌──────────────────────────────┐
│ UC volume (CSV files)        │  /Volumes/dbt/raw/sales_analytics_raw
└──────────────┬───────────────┘
               │ read_files(format => 'csv', inferColumnTypes => false)
┌──────────────▼───────────────┐
│ BRONZE  dbt.bronze.stg_*     │  all columns STRING + _ingest_ts, _source_file
└──────────────┬───────────────┘
               │ parse / clean / dedupe / map values
┌──────────────▼───────────────┐
│ SILVER  dbt.silver.slv_*     │  typed, canonical, deduped
│         quarantine_records   │  rows that violate an invariant
└──────────────┬───────────────┘
               │ conform + as-of SCD2 joins
┌──────────────▼───────────────┐
│ GOLD    dbt.gold.dim_*       │  star schema for BI
│         dbt.gold.fct_*       │
└──────────────────────────────┘
```

Full design rationale: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Repository layout

```
sales_analytics/
├── dbt_project.yml               # project config, vars, per-layer settings
├── profiles.yml                  # dev/prod targets, token from env
├── databricks.yml                # Asset Bundle definition (dev/prod)
├── resources/dbt_job.yml         # scheduled Databricks job (dbt_task)
├── models/
│   ├── staging/                  # bronze: 7 stg_* models
│   ├── silver/                   # 7 slv_* models + quarantine_records
│   ├── gold/                     # 5 dim_* + 3 fct_* models
│   └── observability/            # audit timeline + idempotency views
├── macros/
│   ├── transform_helpers.sql     # cleaning / parsing / hashing helpers
│   ├── incremental_helpers.sql   # late-arriving window + reconciliation
│   ├── logging.sql               # structured model/step/run logging
│   ├── observability.sql         # audit table DDL + row/hash metrics
│   └── generate_schema_name.sql  # use custom schema names as-is
├── tests/                        # 4 singular SCD2 invariant tests
├── snapshots/stores_snapshot.sql # dbt snapshot on stores
├── analyses/check_table.sql      # ad-hoc analysis (not materialized)
├── scripts/
│   ├── build.ps1                 # local build helper
│   ├── deploy.ps1                # bundle validate + deploy helper
│   └── run_scheduler.ps1         # start the local scheduler dashboard
├── scheduler/                    # Flask + APScheduler local dashboard
│   ├── app.py                    # routes, schedule, run lifecycle
│   ├── runner.py                 # dbt subprocess, token, preflight
│   ├── store.py                  # SQLite run history
│   ├── config.py                 # persisted settings
│   ├── templates/ static/        # dashboard UI
│   └── runtime/                  # local state (git-ignored)
├── .github/
│   ├── actions/setup-dbt/        # composite: pinned dbt + credential preflight
│   ├── workflows/dbt_ci.yml      # PR -> dev build, quality gate, artifacts
│   ├── workflows/dbt_deploy.yml  # merge -> gated prod deploy
│   └── pull_request_template.md
└── docs/                         # this documentation set
```

## Quickstart

### Prerequisites

- dbt Fusion on `PATH` (`dbt --version` → `2.0.0-preview.186` or newer)
- Databricks CLI authenticated with a profile named `DEFAULT`
- Access to the SQL warehouse and the `dbt` catalog

### Run locally (PowerShell)

```powershell
cd C:\temp\DBT_project\sales_analytics

# Pull the PAT from the Databricks CLI profile — never hardcode it
$t = (Select-String -Path "$env:USERPROFILE\.databrickscfg" `
      -Pattern '^token\s*=\s*(.+)$').Matches[0].Groups[1].Value.Trim()
$env:DATABRICKS_TOKEN = $t

dbt debug --profiles-dir .
dbt build --profiles-dir .
```

Or use the helper:

```powershell
.\scripts\build.ps1                       # dev target
.\scripts\build.ps1 -Select "gold.fct_sales+"
.\scripts\build.ps1 -FullRefresh
```

### Common commands

| Task | Command |
|---|---|
| Validate connection | `dbt debug --profiles-dir .` |
| Build everything | `dbt build --profiles-dir .` |
| Build one layer | `dbt build --select tag:gold --profiles-dir .` |
| Build a model + downstream | `dbt build --select slv_orders+ --profiles-dir .` |
| Rebuild from scratch | `dbt build --full-refresh --profiles-dir .` |
| Run tests only | `dbt test --profiles-dir .` |
| Compile + docs index | `dbt compile --write-index --profiles-dir .` |
| Serve docs | `dbt docs serve --no-open --port 8580` |
| Start local scheduler | `.\scripts\run_scheduler.ps1` |
| Install scheduler deps | `.\scripts\run_scheduler.ps1 -Install` |
| Follow structured logs | `dbt build --profiles-dir . 2>&1 \| Select-String '\[sales_analytics\]'` |
| Check idempotency | `dbt run-operation check_idempotency --profiles-dir .` |
| Validate bundle | `databricks bundle validate -t dev --profile DEFAULT` |
| Deploy job | `.\scripts\deploy.ps1 -Target prod` |

> `dbt docs generate` is **not supported** on this Fusion preview (error
> `dbt1705`). Use `dbt compile --write-index` and then `dbt docs serve`.
> Column-level lineage requires a dbt platform licence (`dbt1068`).

## Environments

Environment isolation is by **catalog**, so dev and prod never share tables:

| Target | Catalog | Schemas | Threads | Use |
|---|---|---|---|---|
| `dev` (default) | `dbt` | `bronze`, `silver`, `gold` | 4 | local development, PR validation |
| `prod` | `dbt_prod` | `bronze`, `silver`, `gold` | 8 | scheduled production runs |

Select a target with `DBT_TARGET=prod` or `--target prod`. See
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for first-time setup and promotion.

## Local scheduler app

A small Flask + APScheduler dashboard in `scheduler/` runs the dbt build from
this PC every day at **02:30** local time (configurable). It is a local
alternative to the Databricks job; both execute the same dbt project.

```powershell
.\scripts\run_scheduler.ps1
```

The launcher creates `scheduler/.venv`, installs the dependencies once, starts
the app on <http://127.0.0.1:5055>, and opens the dashboard. Keep the process
running — the schedule only fires while the app is up.

| In the dashboard | What it does |
|---|---|
| **Run now** | Queues one build with the saved target/selector |
| **Dev smoke test** | Runs `--target dev --select dim_date` (never touches prod) |
| **Pause / Resume** | Stops or restarts the daily trigger |
| **Schedule form** | Time, target, optional `--select`, `--full-refresh` |
| **Preflight** | Checks `dbt`, token, `profiles.yml`, and the target catalog |
| **Recent runs** | Status, duration, summary, and the full run log |

Defaults: target `dev`, 02:30 local time, whole project. Prod is **locked** in
code: any request for `target=prod` is rejected unless the process was started
with `SCHEDULER_ALLOW_PROD=1`. Even then the dashboard asks for confirmation
before a schedule or manual run is accepted. Settings are stored in
`scheduler/runtime/config.json`; run history and per-run logs live beside it in
`scheduler/runtime/` (git-ignored, and outside dbt's `logs/` so `dbt clean` does
not remove them).

Credentials come from `DATABRICKS_TOKEN` when set, otherwise from the `DEFAULT`
profile in `~/.databrickscfg`. The token is passed to the child process and is
never written to `config.json` or the run logs. The dashboard binds to
`127.0.0.1` only and has no authentication — do not expose it with
`--host 0.0.0.0`.

> The `prod` target needs the `dbt_prod` catalog. Until it exists, preflight
> reports **Catalog 'dbt_prod' does not exist** and production runs fail fast.
> Use the dev smoke test in the meantime.

To start the dashboard automatically at logon, create a Task Scheduler task
whose action is `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
C:\temp\DBT_project\sales_analytics\scripts\run_scheduler.ps1 -NoBrowser` with
trigger **At log on**. Task Scheduler only launches the app; the daily timing
still comes from APScheduler.

## Data domains

| Domain | Bronze rows | Silver rows | Gold output |
|---|---:|---:|---|
| Orders | 1,540 | 1,500 | `fct_sales` 2,957 |
| Order items | 2,997 | 2,967 | — |
| Customers | 327 | 303 | `dim_customers` 303 / `dim_customers_scd2` 315 |
| Products | 44 | 42 | `dim_products` 42 |
| Stores | 10 | 8 | `dim_stores` 8 |
| Payments | 1,638 | 1,618 | `fct_payments` 1,618 |
| Returns | 146 | 141 | `fct_returns` 141 |
| Calendar | — | — | `dim_date` 804 |
| Quarantine | — | 165 | — |

Row counts are a snapshot of the `dev` catalog and will drift as the source
files change.

## CI/CD

| | |
|---|---|
| On every PR | `dbt CI` → `dbt build --target dev`, quality gate, artifacts (14 days) |
| On merge to `main` | `dbt Deploy` → `dbt build --target prod` inside the `production` environment |
| Credentials | Actions secrets `DATABRICKS_HOST`, `DATABRICKS_HTTP_PATH`, `DATABRICKS_TOKEN` |
| Toolchain | dbt Fusion `2.0.11`, pinned in `.github/actions/setup-dbt` |
| Quality gate | fails the run if warnings exceed the documented baseline of 5 |

Prod deploys wait for approval once required reviewers are configured on the
`production` environment. Full reference - workflows, secrets, approvals,
ruleset, troubleshooting: [docs/CI_CD.md](docs/CI_CD.md).

## Documentation

| Document | What it covers |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layers, data flow, SCD2 and incremental design decisions |
| [docs/DATA_DICTIONARY.md](docs/DATA_DICTIONARY.md) | Every table and column, with types and business meaning |
| [docs/DATA_QUALITY.md](docs/DATA_QUALITY.md) | Test strategy, the 17 quarantine rules, known issues |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | Daily operations, backfills, troubleshooting, recovery |
| [docs/CI_CD.md](docs/CI_CD.md) | Pipeline reference: workflows, secrets, approvals, quality gate, troubleshooting |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Setup, bundle deploy, promotion, rollback |
| [docs/SECURITY.md](docs/SECURITY.md) | Secrets, token rotation, least privilege, PII handling |

## Logging and audit

Logging has two sinks: greppable console lines and a queryable Delta table.

### Console lines

Every model emits structured `start` / `end` lines automatically via
project-level hooks, and multi-stage models log their intermediate steps:

```
[sales_analytics] run=start target=dev catalog=dbt ts=2026-11-05 15:41:06
[sales_analytics] model=slv_orders step=start target=dev catalog=dbt schema=silver
[sales_analytics] model=slv_orders step=parse target=dev catalog=dbt schema=silver
[sales_analytics] model=slv_orders step=reconcile target=dev catalog=dbt schema=silver
[sales_analytics] model=slv_orders step=final target=dev catalog=dbt schema=silver
[sales_analytics] model=slv_orders step=end target=dev catalog=dbt schema=silver
[sales_analytics] run=end total=98 success=93 warn=5 error=0 other=0
```

### Audit table

`on-run-start` creates `<catalog>.observability.pipeline_step_log` and every
run appends:

| Event | `step` | Carries |
|---|---|---|
| Run start / end | `run_start` / `run_end` | status counts |
| Model start | `start` | timestamp |
| Inline step | e.g. `parse`, `reconcile` | detail |
| Model end | `end` | `rows_read`, `rows_written`, `content_hash` |

`rows_read` is the sum of the model's direct parent row counts (for bronze,
where there is no parent, it falls back to the model's own row count).
`rows_written` is `count(*)` of the model relation after materialisation.
`content_hash` is `sum(hash(...))` over stable business columns only;
`_ingest_ts`, `_loaded_at`, `detected_at` and `dbt_*` columns are excluded so a
re-run of an idempotent model hashes identically.

The two observability views record **NULL metrics** on their own `end` rows:
computing their metrics would read `pipeline_step_log` inside the same
transaction that appends to it, which a concurrent hook append can invalidate
(`DELTA_CONCURRENT_APPEND.ROW_LEVEL_CHANGES`, hit by `pipeline_step_timeline`
in both dev and prod on 2026-11-06). See `model_reads_audit` in
`macros/observability.sql`. They are excluded from the idempotency claim above
by design (`idempotency_check` filters on `schema_name`).

```sql
select model_name, rows_read, rows_written, content_hash
from dbt.observability.pipeline_step_log
where step = 'end' and status = 'success'
order by logged_at desc;
```

### Step timeline

`dbt.observability.pipeline_step_timeline` orders each model's events
`start → steps → end` and attaches the model's row metrics to every step:

```sql
select model_name, phase, step, status, rows_read, rows_written, detail
from dbt.observability.pipeline_step_timeline
where run_id = (select run_id from dbt.observability.pipeline_step_log
                where step = 'run_end' order by logged_at desc limit 1)
order by model_name, phase;
```

### Idempotency check

`dbt.observability.idempotency_check` compares the latest two successful `end`
rows per model:

```sql
select model_name, previous_rows_written, latest_rows_written,
       row_delta, content_unchanged, is_idempotent
from dbt.observability.idempotency_check
order by is_idempotent, model_name;
```

`is_idempotent` is true when both the row count and the content hash are
unchanged; `NULL` means the model has only one observed run. The same verdict
is available from the CLI:

```powershell
dbt run-operation check_idempotency --profiles-dir .
```

Current dev result: **24/24 pipeline models idempotent, max `row_delta` = 0**.

Logging is gated on dbt's `execute` flag, so parse-time rendering stays silent
and only real executions are logged. See `macros/logging.sql`,
`macros/observability.sql`, and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#48-logging-and-observability).

## Documentation coverage

Every model and column has a description in its layer's `schema.yml`
(`staging`, `silver`, `gold`, `observability`), and `+persist_docs` publishes
those descriptions to Unity Catalog. Tests are declared alongside the models
they protect.

## Key design points

- **Late-arriving data is first-class.** Incremental models re-read a window
  (`late_arriving_lookback_days`, default 3) behind the stored watermark and
  reconcile against the target, so an older row can never regress a newer one.
- **SCD2 without close-out updates.** `dim_customers_history` is insert-only,
  keyed on `(customer_id, valid_from)`; `dim_customers_scd2` derives
  `valid_to` / `is_current` on read, so out-of-order versions are handled with
  no UPDATE job.
- **Bad rows are quarantined, not silently dropped.**
  `silver.quarantine_records` records each failed invariant with a
  `reject_reason`.
- **Tests encode intent.** Structural invariants fail the build; known dirty
  data warns.
- **Every run is auditable and idempotency-checkable.** Model end rows record
  `rows_read`, `rows_written` and a stable content hash; the
  `observability.idempotency_check` view compares the latest two runs per model.
- **No secrets in the repo.** `profiles.yml` reads the PAT from
  `DATABRICKS_TOKEN`.

## Known caveats

- The practice dataset is intentionally dirty; 5 tests warn by design.
- `dbt_prod` catalog does not exist yet — create it before the first prod run.
- The local scheduler must stay running; a run missed while it is closed is not
  backfilled automatically.
- The scheduled job is deployed **paused**; unpause after a successful manual run.
- `lineage.html` / `generate_lineage_html.py` are local tooling, not part of the
  dbt project.
- See [docs/SECURITY.md](docs/SECURITY.md) for an outstanding credential
  rotation action.
