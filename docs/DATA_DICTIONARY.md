# Data dictionary

All objects live in Unity Catalog. `<catalog>` is `dbt` in dev and `dbt_prod` in
production. Schema names are identical in both environments.

## Conventions

| Convention | Meaning |
|---|---|
| `STRING` in bronze | Raw source value, not yet parsed |
| `DECIMAL` | Databricks `DECIMAL(18,2)` unless noted |
| `UNKNOWN` | Sentinel for a value that cannot be resolved (never a silent NULL) |
| `_ingest_ts` | Timestamp the row was read from the volume |
| `_source_file` | Volume path the row came from |
| `_loaded_at` | Timestamp a gold history row was written |
| `valid_to = 9999-12-31` | Open-ended SCD2 version |
| `date_key` | Integer `yyyyMMdd` (e.g. `20260131`) |

Row counts below are from the `dev` catalog and are a point-in-time snapshot.

---

## Bronze — `<catalog>.bronze`

Raw copies of the seven CSV extracts. Every source column is `STRING`; the only
typed columns are the two audit columns.

### `stg_orders` — 1,540 rows

Source: `orders_raw.csv`

| Column | Type | Description |
|---|---|---|
| `order_id` | STRING | Order business key |
| `customer_id` | STRING | FK to customer |
| `order_date` | STRING | Raw order date (mixed formats) |
| `order_status` | STRING | Raw status (mixed casing) |
| `channel` | STRING | Sales channel |
| `store_id` | STRING | FK to store |
| `total_amount` | STRING | Raw amount (may contain currency symbols) |
| `discount_pct` | STRING | Raw discount percentage |
| `created_at` | STRING | Raw creation timestamp |
| `last_modified_at` | STRING | Raw last-update timestamp (watermark source) |
| `_ingest_ts` | TIMESTAMP | Read timestamp |
| `_source_file` | STRING | Volume path |

### `stg_order_items` — 2,997 rows

Source: `order_items_raw.csv`

| Column | Type | Description |
|---|---|---|
| `order_item_id` | STRING | Order-line business key |
| `order_id` | STRING | FK to order |
| `product_id` | STRING | FK to product |
| `quantity` | STRING | Raw quantity (may be a word, e.g. `two`) |
| `unit_price` | STRING | Raw unit price |
| `line_total` | STRING | Raw line total |
| `_ingest_ts` | TIMESTAMP | Read timestamp |
| `_source_file` | STRING | Volume path |

### `stg_customers` — 327 rows

Source: `customers_raw.csv`

| Column | Type | Description |
|---|---|---|
| `customer_id` | STRING | Customer business key |
| `first_name` | STRING | First name |
| `last_name` | STRING | Last name |
| `email` | STRING | Email (PII) |
| `phone` | STRING | Phone (PII) |
| `city` | STRING | City |
| `state` | STRING | State |
| `country` | STRING | Country |
| `signup_date` | STRING | Raw signup date |
| `customer_segment` | STRING | Segment |
| `updated_at` | STRING | Raw last-update timestamp (SCD2 `valid_from`) |
| `_ingest_ts` | TIMESTAMP | Read timestamp |
| `_source_file` | STRING | Volume path |

### `stg_products` — 44 rows

Source: `products_raw.csv`

| Column | Type | Description |
|---|---|---|
| `product_id` | STRING | Product business key |
| `product_name` | STRING | Product name |
| `brand` | STRING | Brand |
| `category` | STRING | Category |
| `unit_price` | STRING | Raw selling price |
| `cost_price` | STRING | Raw cost price |
| `currency` | STRING | Currency code |
| `is_active` | STRING | Raw active flag |
| `created_date` | STRING | Raw creation date |
| `_ingest_ts` | TIMESTAMP | Read timestamp |
| `_source_file` | STRING | Volume path |

### `stg_stores` — 10 rows

Source: `stores_raw.csv`

| Column | Type | Description |
|---|---|---|
| `store_id` | STRING | Store business key |
| `store_name` | STRING | Store name |
| `region` | STRING | Region |
| `city` | STRING | City |
| `opened_date` | STRING | Raw opening date |
| `_ingest_ts` | TIMESTAMP | Read timestamp |
| `_source_file` | STRING | Volume path |

### `stg_payments` — 1,638 rows

Source: `payments_raw.csv`

| Column | Type | Description |
|---|---|---|
| `payment_id` | STRING | Payment business key |
| `order_id` | STRING | FK to order |
| `payment_date` | STRING | Raw payment date |
| `payment_method` | STRING | Raw method (mixed casing/format) |
| `amount` | STRING | Raw amount |
| `payment_status` | STRING | Raw status |
| `transaction_ref` | STRING | Payment provider reference |
| `_ingest_ts` | TIMESTAMP | Read timestamp |
| `_source_file` | STRING | Volume path |

### `stg_returns` — 146 rows

Source: `returns_raw.csv`

| Column | Type | Description |
|---|---|---|
| `return_id` | STRING | Return business key |
| `order_item_id` | STRING | FK to order line |
| `return_date` | STRING | Raw return date |
| `reason` | STRING | Raw free-text reason |
| `refund_amount` | STRING | Raw refund amount |
| `_ingest_ts` | TIMESTAMP | Read timestamp |
| `_source_file` | STRING | Volume path |

---

## Silver — `<catalog>.silver`

Typed, canonical, deduplicated. One row per business key.

### `slv_orders` — 1,500 rows (incremental)

Deduped to the newest version per `order_id`. Incremental merge with a
late-arriving window (see [ARCHITECTURE.md](ARCHITECTURE.md#43-late-arriving-window)).

| Column | Type | Description |
|---|---|---|
| `order_id` | STRING | PK |
| `customer_id` | STRING | FK to customer |
| `order_date` | DATE | Parsed order date |
| `order_status` | STRING | Canonical status (`DELIVERED`, `SHIPPED`, …) |
| `channel` | STRING | Canonical channel (`ONLINE`, `STORE`, `APP`) |
| `store_id` | STRING | FK to store (NULL when not store-fulfilled) |
| `total_amount` | DECIMAL | Parsed order total |
| `discount_pct` | DECIMAL(5,2) | Discount percentage |
| `created_at` | TIMESTAMP | Parsed creation time |
| `last_modified_at` | TIMESTAMP | Parsed last-update time (watermark) |
| `_ingest_ts` | TIMESTAMP | Read timestamp |
| `_source_file` | STRING | Volume path |

### `slv_order_items` — 2,967 rows

| Column | Type | Description |
|---|---|---|
| `order_item_id` | STRING | PK |
| `order_id` | STRING | FK to order |
| `product_id` | STRING | FK to product |
| `quantity` | INT | Parsed quantity (words mapped: one→1 … five→5) |
| `unit_price` | DECIMAL(10,2) | Parsed unit price |
| `line_total` | DECIMAL(10,2) | Parsed line total |

### `slv_customers` — 303 rows

Latest version per customer (Type-1 feed for the gold current dimension).

| Column | Type | Description |
|---|---|---|
| `customer_id` | STRING | PK |
| `first_name` | STRING | Trimmed |
| `last_name` | STRING | Trimmed |
| `email` | STRING | Lower-cased (PII) |
| `phone` | STRING | Trimmed (PII) |
| `city` | STRING | Trimmed |
| `state` | STRING | Upper-cased |
| `country` | STRING | Upper-cased |
| `signup_date` | DATE | Parsed |
| `customer_segment` | STRING | Upper-cased |

### `slv_products` — 42 rows

| Column | Type | Description |
|---|---|---|
| `product_id` | STRING | PK |
| `product_name` | STRING | Trimmed |
| `brand` | STRING | Trimmed |
| `category` | STRING | Init-capped; `Unassigned` when missing |
| `unit_price` | DECIMAL(10,2) | Parsed |
| `cost_price` | DECIMAL(10,2) | Parsed |
| `currency` | STRING | Upper-cased; defaults to `INR` |
| `is_active` | BOOLEAN | Parsed flag |
| `created_date` | DATE | Parsed |

### `slv_stores` — 8 rows

| Column | Type | Description |
|---|---|---|
| `store_id` | STRING | PK |
| `store_name` | STRING | Trimmed |
| `city` | STRING | Trimmed |
| `region` | STRING | Upper-cased |
| `opened_date` | DATE | Parsed |

### `slv_payments` — 1,618 rows

| Column | Type | Description |
|---|---|---|
| `payment_id` | STRING | PK |
| `order_id` | STRING | FK to order |
| `payment_date` | DATE | Parsed |
| `payment_method` | STRING | Canonical (`UPI`, `CREDIT CARD`, `DEBIT CARD`, `COD`, `NET BANKING`, `WALLET`, `UNKNOWN`) |
| `amount` | DECIMAL | Parsed |
| `payment_status` | STRING | Canonical (`SUCCESS`, `FAILED`, `PENDING`, `REFUNDED`) |
| `transaction_ref` | STRING | Provider reference, NULL when blank |

### `slv_returns` — 141 rows

| Column | Type | Description |
|---|---|---|
| `return_id` | STRING | PK |
| `order_item_id` | STRING | FK to order line |
| `return_date` | DATE | Parsed |
| `reason` | STRING | Canonical (`DAMAGED`, `WRONG ITEM`, `SIZE ISSUE`, `CHANGED MIND`, `DEFECTIVE`, `NOT AS DESCRIBED`, `UNKNOWN`) |
| `refund_amount` | DECIMAL | Parsed |

### `quarantine_records` — 165 rows

One row per **failed rule per record** (long format). A record that breaks two
rules appears twice.

| Column | Type | Description |
|---|---|---|
| `source_table` | STRING | Silver domain (`orders`, `order_items`, `payments`, `returns`) |
| `record_id` | STRING | Business key of the offending row |
| `reject_reason` | STRING | Machine-readable rule name (see [DATA_QUALITY.md](DATA_QUALITY.md)) |
| `detected_at` | TIMESTAMP | When the check ran |

---

## Gold — `<catalog>.gold`

### Dimensions

#### `dim_customers` — 303 rows (Type 1)

Current-state customer for operational reporting.

| Column | Type | Description |
|---|---|---|
| `customer_id` | STRING | PK |
| `first_name` | STRING | |
| `last_name` | STRING | |
| `full_name` | STRING | `first_name || ' ' || last_name` |
| `email` | STRING | PII |
| `phone` | STRING | PII |
| `city` | STRING | |
| `state` | STRING | |
| `country` | STRING | |
| `signup_date` | DATE | |
| `customer_segment` | STRING | |

#### `dim_customers_history` — 315 rows (incremental)

Insert-only SCD2 version history.

| Column | Type | Description |
|---|---|---|
| `customer_id` | STRING | Part of version key |
| `first_name` … `customer_segment` | — | Same attributes as `slv_customers` |
| `valid_from` | TIMESTAMP | Source `updated_at`; part of version key |
| `row_hash` | STRING | `md5` of the attribute set (change detection) |
| `_loaded_at` | TIMESTAMP | When this version was first observed |

Unique key: `(customer_id, valid_from)`.

#### `dim_customers_scd2` — 315 rows (view)

Type-2 dimension derived from history. Recomputes windows on every read, so
late-arriving versions need no close-out update.

| Column | Type | Description |
|---|---|---|
| `customer_sk` | STRING | Surrogate key `md5(customer_id \|\| valid_from)` |
| `customer_id` | STRING | Natural key |
| `first_name` … `customer_segment` | — | Version attributes |
| `version_number` | INT | 1-based, ordered by `valid_from` |
| `valid_from` | TIMESTAMP | Version start (inclusive) |
| `valid_to` | TIMESTAMP | Next version's `valid_from` (exclusive); `9999-12-31` when current |
| `is_current` | BOOLEAN | True for the open version |
| `row_hash` | STRING | Attribute hash |
| `_loaded_at` | TIMESTAMP | Load timestamp |

#### `dim_products` — 42 rows

| Column | Type | Description |
|---|---|---|
| `product_id` | STRING | PK |
| `product_name` | STRING | |
| `brand` | STRING | |
| `category` | STRING | |
| `unit_price` | DECIMAL | |
| `cost_price` | DECIMAL | |
| `margin_amount` | DECIMAL | `unit_price - cost_price` |
| `currency` | STRING | |
| `is_active` | BOOLEAN | |
| `created_date` | DATE | |

#### `dim_stores` — 8 rows

| Column | Type | Description |
|---|---|---|
| `store_id` | STRING | PK |
| `store_name` | STRING | |
| `city` | STRING | |
| `region` | STRING | |
| `opened_date` | DATE | |

#### `dim_date` — 804 rows

Conformed calendar spanning the order history (plus a small buffer).

| Column | Type | Description |
|---|---|---|
| `date_key` | INT | `yyyyMMdd`, PK |
| `date_day` | DATE | Calendar date, unique |
| `year` | INT | |
| `quarter` | INT | |
| `month` | INT | |
| `month_name` | STRING | e.g. `January` |
| `week_of_year` | INT | |
| `day_of_week` | INT | Databricks convention (1 = Sunday) |
| `day_name` | STRING | e.g. `Monday` |
| `is_weekend` | BOOLEAN | Saturday/Sunday |

### Facts

#### `fct_sales` — 2,957 rows

Order-line grain. `customer_sk` resolved **as of the order date**.

| Column | Type | Description |
|---|---|---|
| `order_item_id` | STRING | PK (order-line grain) |
| `order_id` | STRING | FK to `slv_orders` |
| `customer_sk` | STRING | FK to `dim_customers_scd2`; earliest-version fallback, else `UNKNOWN` |
| `customer_id` | STRING | Degenerate natural key |
| `product_id` | STRING | FK to `dim_products` |
| `store_id` | STRING | FK to `dim_stores` |
| `date_key` | INT | FK to `dim_date` (order date) |
| `order_date` | DATE | Degenerate date |
| `order_status` | STRING | |
| `channel` | STRING | |
| `quantity` | INT | |
| `unit_price` | DECIMAL | |
| `line_total` | DECIMAL | `quantity * unit_price` as supplied |
| `discount_pct` | DECIMAL | Order-level discount |
| `net_amount` | DECIMAL | `line_total * (1 - discount_pct/100)` |

#### `fct_payments` — 1,618 rows

Payment-attempt grain. Retries and split payments remain separate rows.

| Column | Type | Description |
|---|---|---|
| `payment_id` | STRING | PK |
| `order_id` | STRING | FK to order |
| `customer_id` | STRING | From order (NULL if orphan) |
| `store_id` | STRING | From order |
| `date_key` | INT | FK to `dim_date` (payment date) |
| `payment_date` | DATE | |
| `payment_method` | STRING | Canonical method |
| `payment_status` | STRING | Canonical status |
| `amount` | DECIMAL | |
| `transaction_ref` | STRING | |
| `is_successful` | BOOLEAN | `payment_status = 'SUCCESS'` |

#### `fct_returns` — 141 rows

Return-line grain, enriched with the originating order line.

| Column | Type | Description |
|---|---|---|
| `return_id` | STRING | PK |
| `order_item_id` | STRING | FK to `slv_order_items` |
| `order_id` | STRING | From the order line |
| `product_id` | STRING | From the order line |
| `customer_id` | STRING | From the order |
| `store_id` | STRING | From the order |
| `date_key` | INT | FK to `dim_date` (return date) |
| `return_date` | DATE | |
| `reason` | STRING | Canonical reason |
| `refund_amount` | DECIMAL | |
| `line_total` | DECIMAL | Original line total |
| `is_refund_above_line_total` | BOOLEAN | DQ flag |

---

## Snapshot — `<catalog>.snapshots.stores_snapshot`

dbt `check` snapshot on `slv_stores` (`unique_key = store_id`,
`check_cols = store_name, city, region`).

| Column | Type | Description |
|---|---|---|
| `store_id` … `opened_date` | — | Source columns |
| `dbt_scd_id` | STRING | Snapshot row id |
| `dbt_updated_at` | TIMESTAMP | Source update time |
| `dbt_valid_from` | TIMESTAMP | Row validity start |
| `dbt_valid_to` | TIMESTAMP | Row validity end (NULL = current) |

---

## Referential summary

```
dim_customers_scd2.customer_sk  ← fct_sales.customer_sk
dim_products.product_id         ← fct_sales.product_id, fct_returns.product_id
dim_stores.store_id             ← fct_sales.store_id, fct_payments.store_id, fct_returns.store_id
dim_date.date_key               ← fct_sales.date_key, fct_payments.date_key, fct_returns.date_key
slv_orders.order_id             ← fct_sales.order_id, fct_payments.order_id
slv_order_items.order_item_id   ← fct_returns.order_item_id
```

`fct_sales` is an inner join from `slv_order_items` to `slv_orders`, so the 10
order lines with an orphan `order_id` are excluded (2,967 → 2,957). They are
recorded in `quarantine_records` as `orphan_order_id`.
