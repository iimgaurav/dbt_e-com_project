{{ config(materialized='table', tags=['bronze', 'order_items']) }}

{{ log_step('read_csv', detail='order_items_raw.csv') }}

with source as (
    select *
    from read_files(
        '{{ var("raw_volume_path") }}/order_items_raw.csv',
        format => 'csv',
        header => true,
        inferColumnTypes => false
    )
)

select
    order_item_id,
    order_id,
    product_id,
    quantity,
    unit_price,
    line_total,
    current_timestamp() as _ingest_ts,
    '{{ var("raw_volume_path") }}/order_items_raw.csv' as _source_file
from source
