{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='product_id',
    on_schema_change='append_new_columns',
    tags=['gold', 'marts', 'scd1']
) }}

{#
    SCD Type 1 product dimension (production parity:
    silver.usp_scd_type1_products). Each product_id is MERGE-upserted on every
    run, so changed attributes overwrite the previous values and no history is
    kept. slv_products already keeps the latest source version per product.
#}

{{ log_step('enrich') }}

select
    product_id,
    product_name,
    brand,
    category,
    unit_price,
    cost_price,
    cast(round(unit_price - cost_price, 2) as decimal(18, 2)) as margin_amount,
    currency,
    is_active,
    created_date
from {{ ref('slv_products') }}
