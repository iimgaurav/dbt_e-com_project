{{ config(materialized='table', tags=['gold', 'marts']) }}

{{ log_step('enrich') }}

select
    store_id,
    store_name,
    city,
    region,
    opened_date
from {{ ref('slv_stores') }}
