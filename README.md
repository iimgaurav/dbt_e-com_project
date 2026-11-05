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
| CI/CD | GitHub Actions (`.github/workflows/dbt_ci.yml`) |

## Current build status

```
dbt build --profiles-dir .
Processed: 2 hooks | 24 models | 67 tests | 1 snapshot
Summary:   94 total | 89 success | 5 warn
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
│   └── gold/                     # 5 dim_* + 3 fct_* models
├── macros/
│   ├── transform_helpers.sql     # cleaning / parsing / hashing helpers
│   ├── incremental_helpers.sql   # late-arriving window + reconciliation
│   ├── logging.sql               # structured model/step/run logging
│   └── generate_schema_name.sql  # use custom schema names as-is
├── tests/                        # 4 singular SCD2 invariant tests
├── snapshots/stores_snapshot.sql # dbt snapshot on stores
├── analyses/check_table.sql      # ad-hoc analysis (not materialized)
├── scripts/
│   ├── build.ps1                 # local build helper
│   └── deploy.ps1                # bundle validate + deploy helper
├── .github/workflows/dbt_ci.yml  # CI/CD
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
| Follow structured logs | `dbt build --profiles-dir . 2>&1 \| Select-String '\[sales_analytics\]'` |
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

## Documentation

| Document | What it covers |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layers, data flow, SCD2 and incremental design decisions |
| [docs/DATA_DICTIONARY.md](docs/DATA_DICTIONARY.md) | Every table and column, with types and business meaning |
| [docs/DATA_QUALITY.md](docs/DATA_QUALITY.md) | Test strategy, the 17 quarantine rules, known issues |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | Daily operations, backfills, troubleshooting, recovery |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Setup, CI/CD, bundle deploy, promotion, rollback |
| [docs/SECURITY.md](docs/SECURITY.md) | Secrets, token rotation, least privilege, PII handling |

## Logging

Every model emits structured `start` / `end` lines automatically via
project-level hooks, and multi-stage models log their intermediate steps:

```
[sales_analytics] run=start target=dev catalog=dbt ts=2026-11-05 15:41:06
[sales_analytics] model=slv_orders step=start target=dev catalog=dbt schema=silver
[sales_analytics] model=slv_orders step=parse target=dev catalog=dbt schema=silver
[sales_analytics] model=slv_orders step=reconcile target=dev catalog=dbt schema=silver
[sales_analytics] model=slv_orders step=final target=dev catalog=dbt schema=silver
[sales_analytics] model=slv_orders step=end target=dev catalog=dbt schema=silver
[sales_analytics] run=end total=92 success=87 warn=5 error=0 other=0
```

Logging is gated on dbt's `execute` flag, so parse-time rendering stays silent
and only real executions are logged. See `macros/logging.sql` and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#48-logging-and-observability).

## Documentation coverage

Every model and column has a description in its layer's `schema.yml`
(`staging`, `silver`, `gold`), and `+persist_docs` publishes those descriptions
to Unity Catalog. Tests are declared alongside the models they protect.

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
- **No secrets in the repo.** `profiles.yml` reads the PAT from
  `DATABRICKS_TOKEN`.

## Known caveats

- The practice dataset is intentionally dirty; 5 tests warn by design.
- `dbt_prod` catalog does not exist yet — create it before the first prod run.
- The scheduled job is deployed **paused**; unpause after a successful manual run.
- `lineage.html` / `generate_lineage_html.py` are local tooling, not part of the
  dbt project.
- See [docs/SECURITY.md](docs/SECURITY.md) for an outstanding credential
  rotation action.
