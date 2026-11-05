{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key=['customer_id', 'valid_from'],
    tags=['gold', 'scd2']
) }}

{%- set attributes = [
    'first_name', 'last_name', 'email', 'phone', 'city', 'state', 'country',
    'signup_date', 'customer_segment'
] -%}

{#
    SCD2 history table: one row per (customer_id, valid_from) version.
    Insert-only by design - validity windows are derived in dim_customers_scd2.
    Late-arriving versions (an older updated_at arriving after a newer one) are
    handled naturally because each version is keyed by its own valid_from.
#}

with {{ late_arriving_window('valid_from') }},

{{ log_step('parse') }}

parsed as (
    select
        customer_id,
        trim(first_name)                                as first_name,
        trim(last_name)                                 as last_name,
        lower(trim(email))                              as email,
        trim(phone)                                     as phone,
        trim(city)                                      as city,
        upper(trim(state))                              as state,
        upper(trim(country))                            as country,
        {{ parse_date('signup_date') }}                 as signup_date,
        upper(trim(customer_segment))                   as customer_segment,
        {{ parse_timestamp('updated_at') }}             as valid_from,
        current_timestamp()                             as _loaded_at
    from {{ ref('stg_customers') }}
),

{{ log_step('hash') }}

hashed as (
    select
        *,
        {{ record_hash(attributes) }} as row_hash
    from parsed
    cross join late_arriving_window
    where customer_id is not null
      and valid_from is not null
      -- late-arriving window: re-read versions near the current watermark
      and valid_from >= window_start
),

{{ log_step('dedupe') }}

deduped as (
    select
        *,
        row_number() over (
            partition by customer_id, valid_from
            order by _loaded_at desc
        ) as _rn
    from hashed
)

{{ log_step('final') }}

select
    customer_id, {{ attributes | join(', ') }}, valid_from, row_hash, _loaded_at
from deduped
where _rn = 1
