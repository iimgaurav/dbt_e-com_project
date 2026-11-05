{{ config(materialized='table', tags=['bronze', 'customers']) }}

{{ log_step('read_csv', detail='customers_raw.csv') }}

with source as (
    select *
    from read_files(
        '{{ var("raw_volume_path") }}/customers_raw.csv',
        format => 'csv',
        header => true,
        inferColumnTypes => false
    )
)

select
    customer_id,
    first_name,
    last_name,
    email,
    phone,
    city,
    state,
    country,
    signup_date,
    customer_segment,
    updated_at,
    current_timestamp() as _ingest_ts,
    '{{ var("raw_volume_path") }}/customers_raw.csv' as _source_file
from source
