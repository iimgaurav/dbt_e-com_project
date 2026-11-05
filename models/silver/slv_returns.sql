{{ config(materialized='table', tags=['silver', 'returns']) }}

{%- set reason_map = {
    'damaged': 'DAMAGED',
    'damaged item': 'DAMAGED',
    'wrong item': 'WRONG ITEM',
    'size issue': 'SIZE ISSUE',
    'changed mind': 'CHANGED MIND',
    'defective': 'DEFECTIVE',
    'defective item': 'DEFECTIVE',
    'not as described': 'NOT AS DESCRIBED',
    'not as described item': 'NOT AS DESCRIBED'
} -%}

with bronze_returns as (
    select * from {{ ref('stg_returns') }}
),

{{ log_step('map_values') }}

cleaned as (
    select
        trim(return_id)                                 as return_id,
        trim(order_item_id)                             as order_item_id,
        {{ parse_date('return_date') }}                 as return_date,
        {{ map_values('reason', reason_map) }}          as reason,
        {{ clean_amount('refund_amount') }}             as refund_amount,
        row_number() over (
            partition by return_id order by _ingest_ts desc
        ) as rn
    from bronze_returns
    where return_id is not null
)

{{ log_step('final') }}

select
    return_id,
    order_item_id,
    return_date,
    reason,
    refund_amount
from cleaned
where rn = 1
