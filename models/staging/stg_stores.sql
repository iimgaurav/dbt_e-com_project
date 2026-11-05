{{ config(materialized="table", tags=["bronze", "stores"]) }}

{{ log_step('read_csv', detail='stores_raw.csv') }}

with
    source as (
        select *
        from
            read_files(
                '{{ var("raw_volume_path") }}/stores_raw.csv',
                format => 'csv',
                header => true,
                infercolumntypes => false
            )
    )

select
    store_id,
    store_name,
    region,
    city,
    opened_date,
    current_timestamp() as _ingest_ts,
    '{{ var("raw_volume_path") }}/stores_raw.csv' as _source_file
from source
