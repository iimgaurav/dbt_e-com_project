{{ config(materialized='table', tags=['bronze', 'returns']) }}

{{ log_step('read_csv', detail='returns_raw.csv') }}

with source as (
    select *
    from read_files(
        '{{ var("raw_volume_path") }}/returns_raw.csv',
        format => 'csv',
        header => true,
        inferColumnTypes => false
    )
)

select
    return_id,
    order_item_id,
    return_date,
    reason,
    refund_amount,
    current_timestamp() as _ingest_ts,
    '{{ var("raw_volume_path") }}/returns_raw.csv' as _source_file
from source
