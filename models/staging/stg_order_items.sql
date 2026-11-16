{{ config(
    materialized='incremental',
    incremental_strategy='append',
    on_schema_change='sync_all_columns',
    tags=['bronze', 'order_items']
) }}

{#
    Immutable bronze landing (see stg_customers.sql for the pattern):
    re-ingestion is deduplicated on the business-column tuple and
    _ingest_ts is a first-observation timestamp.
#}

{%- set cols = [
    'order_item_id', 'order_id', 'product_id', 'quantity', 'unit_price', 'line_total'
] -%}

{{ log_step('read_csv', detail='order_items_raw.csv') }}

with source as (
    select *
    from read_files(
        '{{ var("raw_volume_path") }}/order_items_raw.csv',
        format => 'csv',
        header => true,
        inferColumnTypes => false
    )
),

hashed as (
    select
        {%- for c in cols %}
        {{ c }}{% if not loop.last %},{% endif %}
        {%- endfor %},
        {{ record_hash(cols) }} as row_hash
    from source
)

{% if is_incremental() %}
, new_rows as (
    select h.*
    from hashed h
    where not exists (
        select 1
        from {{ this }} t
        where
        {%- for c in cols %}
            t.{{ c }} <=> h.{{ c }}{% if not loop.last %} and{% endif %}
        {%- endfor %}
    )
)
{% else %}
, new_rows as (select * from hashed)
{% endif %}

{{ log_step('land', detail='append-only') }}

select
    {%- for c in cols %}
    {{ c }}{% if not loop.last %},{% endif %}
    {%- endfor %},
    current_timestamp() as _ingest_ts,
    '{{ var("raw_volume_path") }}/order_items_raw.csv' as _source_file,
    row_hash
from new_rows
