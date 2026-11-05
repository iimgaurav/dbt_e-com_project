{{ config(materialized='view', tags=['gold', 'scd2']) }}

{#
    Type-2 dimension derived from the insert-only history table.
    valid_to is the next version's valid_from; the open row ends at 9999-12-31.
    Because windows are recomputed from history, late-arriving versions are
    reflected correctly without any UPDATE/close-out job.
#}

with history as (
    select * from {{ ref('dim_customers_history') }}
),

{{ log_step('derive_windows') }}

windowed as (
    select
        *,
        lead(valid_from) over (
            partition by customer_id order by valid_from
        ) as next_valid_from,
        row_number() over (
            partition by customer_id order by valid_from
        ) as version_number
    from history
)

{{ log_step('final') }}

select
    {{ surrogate_key(['customer_id', 'valid_from']) }} as customer_sk,
    customer_id,
    first_name,
    last_name,
    concat_ws(' ', first_name, last_name) as full_name,
    email,
    phone,
    city,
    state,
    country,
    signup_date,
    customer_segment,
    version_number,
    valid_from,
    coalesce(next_valid_from, timestamp '9999-12-31 00:00:00') as valid_to,
    next_valid_from is null as is_current,
    row_hash,
    _loaded_at
from windowed
