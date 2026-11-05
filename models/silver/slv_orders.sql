{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='order_id',
    tags=['silver', 'orders', 'incremental']
) }}

{%- set columns = [
    'order_id', 'customer_id', 'order_date', 'order_status', 'channel', 'store_id',
    'total_amount', 'discount_pct', 'created_at', 'last_modified_at', '_ingest_ts', '_source_file'
] -%}

with {{ late_arriving_window('last_modified_at') }},

{{ log_step('parse') }}

parsed as (
    select
        order_id,
        customer_id,
        {{ parse_date('order_date') }}                as order_date,
        {{ normalize_text('order_status') }}          as order_status,
        {{ normalize_text('channel') }}               as channel,
        nullif(trim(store_id), '')                    as store_id,
        {{ clean_amount('total_amount') }}            as total_amount,
        cast(nullif(trim(discount_pct), '') as decimal(5, 2)) as discount_pct,
        {{ parse_timestamp('created_at') }}           as created_at,
        {{ parse_timestamp('last_modified_at') }}     as last_modified_at,
        _ingest_ts,
        _source_file
    from {{ ref('stg_orders') }}
),

incoming as (
    select {{ columns | join(', ') }}
    from parsed
    cross join late_arriving_window
    where order_id is not null
      -- late-arriving window: re-read rows near the current watermark
      and last_modified_at >= window_start
)

-- union the window with matching target rows and keep the newest version,
-- so a late (older) row can never regress a newer row already in the table
{{ log_step('reconcile', detail='late-arriving window') }}

{{ reconcile_with_target(
    incoming_cte='incoming',
    target_columns=columns | join(', '),
    unique_key='order_id',
    order_by='last_modified_at desc, _ingest_ts desc'
) }}

{{ log_step('final') }}

select {{ columns | join(', ') }}
from deduped
