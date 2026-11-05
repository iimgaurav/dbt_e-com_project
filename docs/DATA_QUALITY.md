# Data quality

## 1. Philosophy

Data quality is enforced at two levels, with different consequences:

| Level | Mechanism | On failure | Purpose |
|---|---|---|---|
| **Structural invariant** | dbt tests, `severity: error` | Build fails | Protects consumers from corrupt marts |
| **Known data issue** | dbt tests, `severity: warn` | Build continues, warning logged | Surfaces dirty source data without blocking delivery |
| **Row-level quarantine** | `silver.quarantine_records` | Rows are tagged, not dropped | Makes bad records inspectable and countable |

The source dataset is a deliberately dirty practice extract. Rules that would
fail on that data are configured as warnings **only where the issue is known
and documented**; everything else fails hard.

## 2. Test inventory

`dbt build` runs **71 tests** (67 generic + 4 singular).

### Generic tests (`schema.yml`)

| Test | Applied to | Severity |
|---|---|---|
| `unique` | All primary keys (`order_id`, `order_item_id`, `customer_id`, `product_id`, `store_id`, `payment_id`, `return_id`, `date_key`, `customer_sk`) | error |
| `not_null` | All keys and required attributes | error (except `slv_orders.order_date` → warn) |
| `accepted_values` | `slv_orders.order_status`, `slv_payments.payment_method`, `slv_payments.payment_status`, `slv_returns.reason` | warn |
| `relationships` | `fct_sales` → orders / products / date; `fct_payments` → orders; `fct_returns` → order items | error for `fct_sales.order_id` and `fct_sales.date_key`; warn for the rest |

### Singular tests (`tests/`)

| Test | Assertion | Severity |
|---|---|---|
| `assert_scd2_one_current_per_customer` | Exactly one `is_current` row per customer | error |
| `assert_scd2_no_gaps_or_overlaps` | `valid_to` of version N equals `valid_from` of N+1 | error |
| `assert_scd2_valid_range` | `valid_to > valid_from` for every version | error |
| `assert_scd2_no_future_versions` | No version starts in the future | warn |

The three error-level SCD2 tests are the core guarantee that the Type-2
dimension is usable for as-of joins.

## 3. The 5 expected warnings

Current build: **97 pass, 5 warn, 0 error**. Each warning is a known property of
the practice dataset:

| # | Test | Count | Explanation |
|---|---|---:|---|
| 1 | `accepted_values_slv_orders_order_status` | 63 | Source contains `COMPLETE` (56) and `CANCELED` (7) in addition to the canonical statuses. Needs a business decision: map `CANCELED → CANCELLED` and `COMPLETE → DELIVERED`, or extend the domain. |
| 2 | `assert_scd2_no_future_versions` | 8 | Customer rows whose source `updated_at` is in the future. Expected in the practice data; harmless for as-of joins because future versions are simply never selected by historical orders. |
| 3 | `relationships_fct_payments_order_id` | 6 | Payments whose `order_id` does not exist in `slv_orders` (also in quarantine as `orphan_order_id`). |
| 4 | `relationships_fct_returns_order_item_id` | 3 | Returns whose `order_item_id` does not exist (also in quarantine as `orphan_order_item_id`). |
| 5 | `relationships_fct_sales_product_id` | 10 | Order lines whose `product_id` does not exist in `dim_products` (also in quarantine as `orphan_product_id`). |

> Why not fix them? These are **source defects**, not pipeline defects. The
> pipeline's job is to expose them (warn + quarantine) rather than invent
> values. When the upstream extract is corrected, the warnings disappear on
> their own.

## 4. Quarantine rules

`silver.quarantine_records` evaluates **17 rules** across four domains. A record
that fails multiple rules appears once per rule. Current total: **165 rows**.

### Orders (60 rows)

| `reject_reason` | Definition | Rows |
|---|---|---:|
| `missing_customer_id` | `customer_id IS NULL` | 8 |
| `orphan_customer_id` | `customer_id` not present in `slv_customers` | 15 |
| `order_date_in_future` | `order_date > current_date()` | 6 |
| `discount_out_of_range` | `discount_pct < 0 OR discount_pct > 100` | 5 |
| `unknown_store_id` | `store_id` not present in `slv_stores` | 6 |
| `missing_channel` | `channel IS NULL OR channel = 'UNKNOWN'` | 20 |

### Order items (65 rows)

| `reject_reason` | Definition | Rows |
|---|---|---:|
| `non_positive_quantity` | `quantity IS NULL OR quantity <= 0` | 5 |
| `missing_unit_price` | `unit_price IS NULL` | 12 |
| `orphan_order_id` | `order_id` not present in `slv_orders` | 10 |
| `orphan_product_id` | `product_id` not present in `slv_products` | 10 |
| `line_total_mismatch` | `abs(line_total - quantity * unit_price) > 0.01` | 28 |

### Payments (29 rows)

| `reject_reason` | Definition | Rows |
|---|---|---:|
| `missing_amount` | `amount IS NULL` | 8 |
| `orphan_order_id` | `order_id` not present in `slv_orders` | 6 |
| `payment_before_order` | `payment_date < order_date` | 15 |

### Returns (11 rows)

| `reject_reason` | Definition | Rows |
|---|---|---:|
| `orphan_order_item_id` | `order_item_id` not present in `slv_order_items` | 3 |
| `refund_above_line_total` | `refund_amount > line_total` | 5 |
| `return_before_order` | `return_date < order_date` | 3 |

### Using the quarantine

```sql
-- Count by rule
select source_table, reject_reason, count(*) as n
from dbt.silver.quarantine_records
group by 1, 2
order by n desc;

-- Inspect the offending orders
select q.reject_reason, o.*
from dbt.silver.quarantine_records q
join dbt.silver.slv_orders o on o.order_id = q.record_id
where q.source_table = 'orders';
```

Quarantine is **additive**: bad rows still exist in silver. Gold models choose
how to handle them (inner joins exclude orphans; `fct_sales` falls back to
`UNKNOWN` for unresolved customers). This is deliberate — different consumers
need different tolerances.

## 5. Adding a rule

1. Add a `union all` branch to `models/silver/quarantine_records.sql`:

   ```sql
   union all
   select 'orders', order_id, 'new_rule_name'
   from orders
   where <condition>
   ```

2. Add a generic test in `models/silver/schema.yml` if the rule should also
   gate the build.
3. Add a row to the rule table above.
4. Run `dbt build --select quarantine_records+ --profiles-dir .` and confirm the
   count.

## 6. Monitoring

Recommended production monitors (not yet automated as alerts):

| Signal | Query | Alert threshold |
|---|---|---|
| Quarantine growth | `select count(*) from silver.quarantine_records` | > 2× trailing 7-day average |
| New reject reason | `select distinct reject_reason from silver.quarantine_records` | any value not in this document |
| UNKNOWN customer SK rate | `select avg(case when customer_sk='UNKNOWN' then 1 else 0 end) from gold.fct_sales` | > 5% |
| SCD2 duplicate current | `select customer_id from gold.dim_customers_scd2 where is_current group by 1 having count(*) > 1` | any row |
| Freshness | `select max(_ingest_ts) from bronze.stg_orders` | older than 24h |
| Row-count drop | compare each gold table to its 7-day average | −20% |
| Idempotency regression | `select count(*) from dbt.observability.idempotency_check where is_idempotent = false` | > 0 |
| Row-count drift | `select max(abs(row_delta)) from dbt.observability.idempotency_check` | > 0 |

## 7. Current baseline (dev catalog)

| Metric | Value |
|---|---:|
| Models | 26 (24 pipeline + 2 observability) |
| Tests | 71 (67 generic + 4 singular) |
| Pass | 97 |
| Warn | 5 |
| Error | 0 |
| Quarantine rows | 165 |
| Idempotent pipeline models | 24 / 24 |
| Max idempotency `row_delta` | 0 |
| `fct_sales` UNKNOWN customer SK | 43 / 2,957 (1.45%) |
| SCD2 versions | 315 across 303 customers (12 customers have 2 versions) |
| SCD2 structural test failures | 0 |
