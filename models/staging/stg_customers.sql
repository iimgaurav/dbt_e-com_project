{{ config(
    materialized='incremental',
    incremental_strategy='append',
    on_schema_change='sync_all_columns',
    tags=['bronze', 'customers']
) }}

{#
    Immutable bronze landing (production parity: bronze keeps every ingested
    version). The raw CSV is re-read on every run, but a record whose
    business-column tuple is already landed is skipped, so:
      - re-ingesting the same file is idempotent (no duplicates),
      - _ingest_ts is a first-observation timestamp (drives source freshness),
      - changed/re-issued records land as new rows (full raw history).
#}

{%- set cols = [
    'customer_id', 'first_name', 'last_name', 'email', 'phone', 'city',
    'state', 'country', 'signup_date', 'customer_segment', 'updated_at'
] -%}

{{ log_step('read_csv', detail='customers_raw.csv') }}

with source as (
    select *
    from read_files(
        '{{ var("raw_volume_path") }}/customers_raw.csv',
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
    '{{ var("raw_volume_path") }}/customers_raw.csv' as _source_file,
    row_hash
from new_rows
