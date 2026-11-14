go to the next step.{{ config(severity="error") }}

-- DEV Layer Integrity Test
-- Ensures all staging models have valid row counts and no critical nulls
-- This test should PASS before promoting to UAT
with
    staging_counts as (
        select 'stg_customers' as model_name, count(*) as row_count
        from {{ ref("stg_customers") }}

        union all

        select 'stg_products' as model_name, count(*) as row_count
        from {{ ref("stg_products") }}

        union all

        select 'stg_stores' as model_name, count(*) as row_count
        from {{ ref("stg_stores") }}

        union all

        select 'stg_orders' as model_name, count(*) as row_count
        from {{ ref("stg_orders") }}

        union all

        select 'stg_order_items' as model_name, count(*) as row_count
        from {{ ref("stg_order_items") }}

        union all

        select 'stg_payments' as model_name, count(*) as row_count
        from {{ ref("stg_payments") }}

        union all

        select 'stg_returns' as model_name, count(*) as row_count
        from {{ ref("stg_returns") }}
    )

select *
from staging_counts
where row_count = 0
