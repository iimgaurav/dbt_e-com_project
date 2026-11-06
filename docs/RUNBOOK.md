# Runbook

Operational guide for running, monitoring and recovering the `sales_analytics`
pipeline.

## 1. Daily operation

| Time | What | Where |
|---|---|---|
| 02:30 IST | Local scheduler `dbt build` (when the dashboard is running) | `scheduler/` dashboard |
| 02:30 IST | Scheduled `dbt build` | Databricks job `sales_analytics_dbt_prod` |
| On failure | Email to the address in `resources/dbt_job.yml` | Databricks job notifications |
| On demand | Manual run / backfill | CLI or job UI |

The scheduled job is deployed **paused**. Unpause it only after the first
successful manual production run (see [DEPLOYMENT.md](DEPLOYMENT.md)).

### What a healthy run looks like

```
Processed: 4 hooks | 26 models | 71 tests | 1 snapshot
Summary:   102 total | 97 success | 5 warn
Finished 'build' with 5 warnings
```

- 0 errors
- exactly 5 warnings (the documented ones in [DATA_QUALITY.md](DATA_QUALITY.md))
- runtime well under the 45-minute CI timeout (local dev ≈ 2 min)

## 2. Running the pipeline

### Local

```powershell
cd C:\temp\DBT_project\sales_analytics

$t = (Select-String -Path "$env:USERPROFILE\.databrickscfg" `
      -Pattern '^token\s*=\s*(.+)$').Matches[0].Groups[1].Value.Trim()
$env:DATABRICKS_TOKEN = $t

dbt build --profiles-dir .
```

### Helper script

```powershell
.\scripts\build.ps1                                   # full dev build
.\scripts\build.ps1 -Select "tag:gold"                # one layer
.\scripts\build.ps1 -Select "slv_orders+"             # model + downstream
.\scripts\build.ps1 -FullRefresh                      # rebuild all tables
.\scripts\build.ps1 -Target prod                      # production catalog
```

### Local scheduler app

The Flask + APScheduler dashboard runs the daily dbt build from this PC.

```powershell
.\scripts\run_scheduler.ps1                # http://127.0.0.1:5055
.\scripts\run_scheduler.ps1 -Port 5060
.\scripts\run_scheduler.ps1 -Install       # install/update dependencies only
.\scripts\run_scheduler.ps1 -NoBrowser
```

- Defaults: `dev`, 02:30 local time, whole project.
- Prod is locked by default. The API rejects `target=prod` and a stale config
  pointing at prod is coerced back to `dev`. To unlock for one process, start
  the app with `SCHEDULER_ALLOW_PROD=1`; the UI then asks for confirmation.
- **Pause** before maintenance; **Resume** recomputes the next run.
- **Run now** uses the saved settings. **Dev smoke test** runs
  `--target dev --select dim_date`.
- A second run is refused while one is active (HTTP 409, "already in
  progress"); APScheduler also enforces `max_instances=1`.
- If the app is closed at 02:30 the run is skipped, not backfilled. Start the
  app and use **Run now**; the incremental design makes the retry safe.
- If the app crashes mid-run, the next startup marks that run **interrupted**.
- Runtime files: `scheduler/runtime/config.json`, `scheduler.db`,
  `scheduler.log`, and `runs/*.log`.

The preflight panel verifies `dbt`, the token, `profiles.yml`, and the target
catalog. A missing `dbt_prod` catalog is reported before any prod run.

### Databricks job

```powershell
# one-off run of the deployed job
databricks bundle run sales_analytics_dbt -t prod --profile DEFAULT
```

Or open **Workflows → Jobs → `sales_analytics_dbt_prod` → Run now**.

## 3. Backfills and full refresh

### Late-arriving data (small window)

The incremental models already re-read `late_arriving_lookback_days` (default
3) behind the watermark. For a gap within that window, just re-run:

```powershell
dbt build --select slv_orders+ --profiles-dir .
```

### Backfill older than the lookback

Widen the window for one run, then restore the default:

```powershell
dbt build --select slv_orders+ --profiles-dir . --vars "{late_arriving_lookback_days: 30}"
```

### Full rebuild

Use when logic changed in a way that affects history, or to recover from
corruption:

```powershell
dbt build --full-refresh --profiles-dir .
```

> `--full-refresh` drops and recreates incremental models
> (`slv_orders`, `dim_customers_history`). The SCD2 view rebuilds automatically.
> This is safe but re-reads all source files.

### Re-pointing the source volume

```powershell
$env:DBT_RAW_VOLUME_PATH = "/Volumes/dbt/raw/sales_analytics_raw_v2"
dbt build --select tag:bronze+ --profiles-dir . --full-refresh
```

## 4. Verification queries

Run after any backfill or incident.

```sql
-- Row counts per layer
select 'bronze.orders' t, count(*) n from dbt.bronze.stg_orders
union all select 'silver.orders', count(*) from dbt.silver.slv_orders
union all select 'gold.fct_sales', count(*) from dbt.gold.fct_sales;

-- SCD2 structural invariants (all must return 0 rows)
select customer_id from dbt.gold.dim_customers_scd2
where is_current group by 1 having count(*) <> 1;

select a.customer_id from dbt.gold.dim_customers_scd2 a
join dbt.gold.dim_customers_scd2 b
  on a.customer_id = b.customer_id and b.version_number = a.version_number + 1
where a.valid_to <> b.valid_from;

-- Unresolved customer keys
select count(*) filter (where customer_sk = 'UNKNOWN') as unknown_sk,
       count(*) as total
from dbt.gold.fct_sales;

-- Quarantine by rule
select source_table, reject_reason, count(*) n
from dbt.silver.quarantine_records
group by 1,2 order by n desc;
```

### Audit log and idempotency

The pipeline writes every run, model and step to
`<catalog>.observability.pipeline_step_log`. The `end` row carries
`rows_read`, `rows_written` and `content_hash`.

```sql
-- Latest model metrics
select model_name, schema_name, rows_read, rows_written, content_hash, logged_at
from dbt.observability.pipeline_step_log
where step = 'end' and status = 'success'
order by logged_at desc;

-- Step timeline for the latest run
select model_name, phase, step, status, rows_read, rows_written, detail
from dbt.observability.pipeline_step_timeline
where run_id = (select run_id from dbt.observability.pipeline_step_log
                where step = 'run_end' order by logged_at desc limit 1)
order by model_name, phase, logged_at;

-- Idempotency verdict
select model_name, previous_rows_written, latest_rows_written,
       row_delta, content_unchanged, is_idempotent
from dbt.observability.idempotency_check
order by is_idempotent, model_name;
```

The CLI equivalent:

```powershell
dbt run-operation check_idempotency --profiles-dir .
```

Run the build twice to establish a baseline. The second run must produce the
same row counts and content hashes:

```powershell
dbt build --profiles-dir .
dbt build --profiles-dir .
```

Expected: `is_idempotent = true` for all pipeline models and `row_delta = 0`.
If a model is false, inspect the two `end` rows and diff the business columns.
The content hash intentionally excludes `_ingest_ts`, `_loaded_at`,
`detected_at` and `dbt_*`, so those changing is not a failure.

## 5. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Invalid access token` / 403 | `DATABRICKS_TOKEN` not set or expired | Re-export the token from `~/.databrickscfg`; rotate if expired |
| `Cannot connect to warehouse` | Warehouse stopped or wrong `http_path` | Start warehouse `faced73bbff7e9f2`; check `DATABRICKS_HTTP_PATH` |
| `TABLE_OR_VIEW_NOT_FOUND` on a model | First run in a fresh catalog, or `--select` skipped a parent | Run `dbt build` without `--select`, or select with `+` |
| `dbt1159 Deprecated test arguments` | Old `to`/`field`/`values` at top level | Move them under `arguments:` (Fusion requirement) |
| `INVALID_WHERE_CONDITION` | Aggregate scalar subquery in `WHERE` (Databricks limitation) | Use the `late_arriving_window` CTE + `cross join` |
| `dbt1705 docs generate unsupported` | Fusion preview limitation | Use `dbt compile --write-index` then `dbt docs serve` |
| `dbt1068 column-level lineage` | Requires dbt platform licence | Use model-level lineage only |
| `Please use the UI to create a catalog with Default Storage` | CLI cannot create catalogs in this workspace | Create the catalog in the Databricks UI, or `CREATE CATALOG` via SQL |
| `read_files` path error | PowerShell rewrote `/Volumes/...` to backslashes | Use `dbfs:/Volumes/...` with `databricks fs`, or quote the path |
| Build fails on `relationships_fct_sales_order_id` | `slv_orders` not rebuilt | `dbt build --select slv_orders+` |
| Snapshot fails | `slv_stores` missing or empty | Rebuild silver first: `dbt build --select slv_stores+` |
| `TABLE_OR_VIEW_NOT_FOUND observability.pipeline_step_log` | `on-run-start` hooks did not run, or the catalog is missing | Run a full `dbt build`; confirm `CREATE SCHEMA` privilege on the catalog |
| `idempotency_check` is all NULL | Only one run has been observed | Run `dbt build` a second time, then re-query |
| `ConcurrentAppendException` on the audit table | Parallel model threads appended at the same instant | Retry the run; Delta appends are safe to replay |
| Scheduler dashboard does not open | Port 5055 already in use | `.\scripts\run_scheduler.ps1 -Port 5060` |
| `Catalog 'dbt_prod' does not exist` | Prod catalog not created | Create it in the Databricks UI, then click **Recheck** |
| Scheduler never fires | App not running, or paused | Start `run_scheduler.ps1`; the dashboard must say **Armed** |
| `No module named flask` | Scheduler venv not bootstrapped | `.\scripts\run_scheduler.ps1 -Install` |
| Run stuck as **running** after a crash | Process killed mid-run | Restart the app; stale runs are marked interrupted |

### Where the logs are

| Log | Location |
|---|---|
| dbt run log | `logs/dbt.log` |
| Scheduler run logs | `scheduler/runtime/runs/*.log` |
| Scheduler run history | `scheduler/runtime/scheduler.db` (SQLite) |
| Scheduler app log | `scheduler/runtime/scheduler.log` |
| Rendered SQL per node | `target/run/` |
| Compiled SQL | `target/compiled/` |
| Run results (JSON) | `target/run_results.json` |
| Audit table | `dbt.observability.pipeline_step_log` (prod: `dbt_prod.observability.pipeline_step_log`) |
| Step timeline view | `dbt.observability.pipeline_step_timeline` |
| Idempotency view | `dbt.observability.idempotency_check` |
| Databricks job output | Job run UI → task `dbt_build` |

### Structured logs

Every run emits greppable key/value lines for the run, each model, and each
model step:

```powershell
dbt build --profiles-dir . 2>&1 | Select-String '\[sales_analytics\]'
```

```
[sales_analytics] run=start target=dev catalog=dbt ts=...
[sales_analytics] model=slv_orders step=start ... schema=silver
[sales_analytics] model=slv_orders step=parse ... schema=silver
[sales_analytics] model=slv_orders step=reconcile detail=late-arriving window ...
[sales_analytics] model=slv_orders step=final ... schema=silver
[sales_analytics] model=slv_orders step=end ... schema=silver
[sales_analytics] run=end total=98 success=93 warn=5 error=0 other=0
```

Useful filters:

| Goal | Filter |
|---|---|
| One model | `Select-String 'model=slv_orders'` |
| All failures | `Select-String 'error=[1-9]|step=error'` |
| Run summary only | `Select-String 'run=(start|end)'` |
| Late-arriving reconciliation | `Select-String 'step=reconcile'` |

## 6. Recovery scenarios

### A. A model is wrong and gold is corrupted

1. Fix the SQL.
2. `dbt build --select <model>+ --full-refresh --profiles-dir .`
3. Re-run verification queries.
4. Confirm the 5-warning baseline.

### B. Bad source file was loaded

1. Correct or replace the file in the volume.
2. `dbt build --select tag:bronze+ --full-refresh --profiles-dir .`
3. Bronze re-reads the volume; silver/gold rebuild from it.

### C. SCD2 invariant test fails

1. Inspect the failing test output in `target/run_results.json`.
2. Common cause: a customer has two rows with the same `valid_from` but
   different attributes. Check `dim_customers_history` for duplicate
   `(customer_id, valid_from)` — the merge should prevent this.
3. If history is genuinely corrupt:
   `dbt build --select dim_customers_history+ --full-refresh`.

### D. Warehouse unavailable at 02:30

The job fails and emails. Start the warehouse and re-run the job manually; the
incremental design makes the retry safe.

### E. Token leaked

Follow [SECURITY.md](SECURITY.md#3-token-rotation) immediately: rotate, update
the secret, redeploy.

### F. The scheduler app was closed at 02:30

Start it with `.\scripts\run_scheduler.ps1` and click **Run now**. The build is
idempotent and the incremental models re-read the late-arriving window, so a
same-day retry is safe.

## 7. On-call checklist

- [ ] The local scheduler (if used) says **Armed** and its last run succeeded
- [ ] Job status is **Succeeded** (not just "completed with warnings")
- [ ] Warning count is exactly 5 and matches the documented set
- [ ] No new `reject_reason` values in `quarantine_records`
- [ ] `fct_sales` UNKNOWN rate ≤ 5%
- [ ] SCD2 structural tests return 0 rows
- [ ] Bronze `_ingest_ts` is fresh (< 24 h)
- [ ] Gold row counts within ±20% of the 7-day average
- [ ] `observability.idempotency_check` shows `is_idempotent = true` and
      `row_delta = 0` for all pipeline models
- [ ] The latest `pipeline_step_log` `run_end` row has `status = 'success'`

## 8. Change management

| Change | Required validation |
|---|---|
| New model | `dbt build --select <model>+`; add tests + dictionary entry |
| New DQ rule | rebuild `quarantine_records`, document the rule |
| Config / target change | `dbt debug` on both dev and prod |
| Scheduler schedule/target | Save in the dashboard; confirm the next run time |
| Bundle change | `databricks bundle validate -t dev` **and** `-t prod` |
| Macro change | full `dbt build` (macros affect many models) |
| Dependency bump | CI run + manual comparison of row counts |
