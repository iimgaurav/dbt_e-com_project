{{ config(materialized='table', tags=['bronze', 'payments']) }}

{{ log_step('read_csv', detail='payments_raw.csv') }}

with source as (
    select *
    from read_files(
        '{{ var("raw_volume_path") }}/payments_raw.csv',
        format => 'csv',
        header => true,
        inferColumnTypes => false
    )
)

select
    payment_id,
    order_id,
    payment_date,
    payment_method,
    amount,
    payment_status,
    transaction_ref,
    current_timestamp() as _ingest_ts,
    '{{ var("raw_volume_path") }}/payments_raw.csv' as _source_file
from source
