# scheduler/ — local development tooling only

The `scheduler/` directory is a **local dev convenience** for this practice
project. It is NOT production infrastructure.

## What it is

A simple local loop that triggers dbt builds on a timer so the project keeps
exercising its incremental path while you work with the repo open.

## What it is NOT

- **Not the production scheduler.** Production scheduling is the Databricks
  job defined in [`resources/dbt_job.yml`](../resources/dbt_job.yml)
  (02:30 daily, Asia/Kolkata), deployed via the bundle
  (`databricks bundle deploy -t prod`) and managed with
  [`scripts/prod_cutover.ps1`](../scripts/prod_cutover.ps1).
- **No backfill.** If your laptop (and therefore the local scheduler) is shut
  down, a missed run is *not* replayed later. The next run simply processes
  whatever the raw CSVs contain at that point — fine for this dataset, but
  never rely on it for freshness.

## Where to point people

- Scheduled production runs → `resources/dbt_job.yml` + `docs/PROD_CUTOVER.md`.
- CI scheduling (PR/push promotion) → `.github/workflows/dbt_pipeline.yml`.
