# Production cutover runbook

This runbook takes the sales_analytics dbt project from local dev to a live
scheduled production job. It covers the one-time setup, the gating applied by
CI, and the manual cutover path when you need to promote from a machine.

## Prerequisites

- dbt Fusion CLI (`dbt`) and the Databricks CLI (`databricks`) installed locally.
- `DATABRICKS_HOST` and `DATABRICKS_TOKEN` exported (token must have Unity
  Catalog privileges listed below).
- The SQL warehouse id in `databricks.yml` (`warehouse_id`) is running.

## 1. GitHub environment protection (one-time)

The pipeline deploys through two GitHub environments, `uat` and `production`
(declared via `environment:` in `.github/workflows/dbt_pipeline.yml`).
Configure them under **Repo → Settings → Environments**:

| Environment | Required reviewers | Secrets |
|---|---|---|
| `uat` | 1 data engineer | `DATABRICKS_HOST`, `DATABRICKS_HTTP_PATH`, `DATABRICKS_TOKEN` |
| `production` | 2 reviewers (e.g. data lead + on-call) | `DATABRICKS_HOST`, `DATABRICKS_HTTP_PATH`, `DATABRICKS_TOKEN` |

Deployment gating enforced by the workflow:

- `dev-build` runs on every PR and every push to `main`.
- `uat-build` runs when dispatching `environment: uat|prod`, **and** on every
  push to `main` (so prod is never reached without a passing UAT build).
- `prod-deploy` `needs: [dev-build, uat-build]`: dispatching `environment:
  prod` or pushing to `main` both route through a green UAT build. The
  `skip_uat` input exists for emergencies only and only applies to manual
  dispatches.

## 2. Catalog setup (one-time per workspace)

Run `resources/prod_catalog_setup.sql` once in the Databricks SQL editor with
a privileged identity. It creates `dbt_uat` and `dbt_prod` with the
`bronze / silver / gold / observability / snapshots` schemas and grants
CREATE/MODIFY/SELECT to the CI service principal (replace the
`<data-eng-group>` placeholders). It is idempotent - safe to re-run.

> The `observability` schema is where `pipeline_step_log` (audit log) and
> `watermark_table` (per-model high-water marks) live; both are created
> automatically by the `on-run-start` / `on-run-end` hooks.

## 3. First prod run (manual)

Either push to `main` (CI runs dev → uat → prod with environment approvals),
or run the cutover script from a machine:

```powershell
.\scripts\prod_cutover.ps1
```

The script builds UAT, builds PROD, deploys the bundle (`databricks bundle
deploy -t prod`) and runs the deployed job once (`databricks bundle run`).
The job is deployed **paused** on purpose: verify the manual run before the
schedule goes live. Then unpause:

```powershell
.\scripts\prod_cutover.ps1 -Unpause
```

Useful flags: `-FullRefresh` (rebuild incremental models from scratch),
`-SkipProdBuild` (stop after the UAT build).

## 4. Source freshness

`models/staging/sources.yml` declares the seven bronze landing tables as
sources with `loaded_at_field: _ingest_ts` and a 24 h warn / 168 h error SLA.
Check recency any time with:

```bash
dbt source freshness --profiles-dir . --target prod
```

Non-zero exit = the error SLA was breached (an upstream feed stopped).

## 5. Version pinning

The CI workflow pins dbt Fusion to `DBT_VERSION` (currently `2.0.11`,
`.github/actions/setup-dbt`). Artifacts (manifest, run_results) regenerate
under that version. When bumping the pin, expect artifact schema drift and
re-baseline `EXPECTED_WARNINGS` if dbt changes its warning taxonomy; run the
dev job locally first and diff `target/run_results.json` before merging.

## 6. Post-cutover tuning

- **Quarantine threshold**: `quarantine_alert_threshold` (default 2000) is
  deliberately generous for the known-dirty practice dataset (~165 rows
  quarantined). After the first prod run, set it to roughly 2x the real
  baseline in `dbt_project.yml` so a quarantine blow-up fails the build.
- **Watermarks**: confirm rows appear in `<catalog>.observability.watermark_table`
  for `slv_orders` and `dim_customers_history` after each scheduled run; the
  `batch_id` column joins to `pipeline_step_log.run_id`.
