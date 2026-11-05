{{ config(materialized="table", tags=["bronze", "products"]) }}

{{ log_step('read_csv', detail='products_raw.csv') }}

with
    source as (
        select *
        from
            read_files(
                '{{ var("raw_volume_path") }}/products_raw.csv',
                format => 'csv',
                header => true,
                infercolumntypes => false
            )
    )

select
    product_id,
    product_name,
    brand,
    category,
    unit_price,
    cost_price,
    currency,
    is_active,
    created_date,
    current_timestamp() as _ingest_ts,
    '{{ var("raw_volume_path") }}/products_raw.csv' as _source_file
from source
