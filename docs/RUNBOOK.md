# Runbook

Operational guide for running, monitoring and recovering the `sales_analytics`
pipeline.

## 1. Daily operation

| Time | What | Where |
|---|---|---|
| 02:30 IST | Scheduled `dbt build` | Databricks job `sales_analytics_dbt_prod` |
| On failure | Email to the address in `resources/dbt_job.yml` | Databricks job notifications |
| On demand | Manual run / backfill | CLI or job UI |

The scheduled job is deployed **paused**. Unpause it only after the first
successful manual production run (see [DEPLOYMENT.md](DEPLOYMENT.md)).

### What a healthy run looks like

```
Processed: 2 hooks | 24 models | 67 tests | 1 snapshot
Summary:   94 total | 89 success | 5 warn
Finished 'build' with 5 warnings
```

- 0 errors
- exactly 5 warnings (the documented ones in [DATA_QUALITY.md](DATA_QUALITY.md))
- runtime well under the 45-minute CI timeout (local dev ≈ 45 s)

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

### Idempotency check

Run the build twice. The second run must produce the same row counts:

```powershell
dbt build --profiles-dir .
dbt build --profiles-dir .
```

Expected: identical counts, no duplicate keys. If counts grow, the merge key or
the dedupe window is wrong.

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

### Where the logs are

| Log | Location |
|---|---|
| dbt run log | `logs/dbt.log` |
| Rendered SQL per node | `target/run/` |
| Compiled SQL | `target/compiled/` |
| Run results (JSON) | `target/run_results.json` |
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
[sales_analytics] run=end total=92 success=87 warn=5 error=0 other=0
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

## 7. On-call checklist

- [ ] Job status is **Succeeded** (not just "completed with warnings")
- [ ] Warning count is exactly 5 and matches the documented set
- [ ] No new `reject_reason` values in `quarantine_records`
- [ ] `fct_sales` UNKNOWN rate ≤ 5%
- [ ] SCD2 structural tests return 0 rows
- [ ] Bronze `_ingest_ts` is fresh (< 24 h)
- [ ] Gold row counts within ±20% of the 7-day average

## 8. Change management

| Change | Required validation |
|---|---|
| New model | `dbt build --select <model>+`; add tests + dictionary entry |
| New DQ rule | rebuild `quarantine_records`, document the rule |
| Config / target change | `dbt debug` on both dev and prod |
| Bundle change | `databricks bundle validate -t dev` **and** `-t prod` |
| Macro change | full `dbt build` (macros affect many models) |
| Dependency bump | CI run + manual comparison of row counts |
