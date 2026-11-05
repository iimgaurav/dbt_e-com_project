{{ config(materialized='table', tags=['bronze', 'orders']) }}

{{ log_step('read_csv', detail='orders_raw.csv') }}

with source as (
    select *
    from read_files(
        '{{ var("raw_volume_path") }}/orders_raw.csv',
        format => 'csv',
        header => true,
        inferColumnTypes => false
    )
)

select
    order_id,
    customer_id,
    order_date,
    order_status,
    channel,
    store_id,
    total_amount,
    discount_pct,
    created_at,
    last_modified_at,
    current_timestamp() as _ingest_ts,
    '{{ var("raw_volume_path") }}/orders_raw.csv' as _source_file
from source
