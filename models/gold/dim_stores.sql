{{ config(materialized='table', tags=['gold', 'marts']) }}

{{ log_step('enrich') }}

select
    s.store_id,
    s.store_name,
    s.city,
    s.region,
    s.opened_date,
    r.region_sk
from {{ ref('slv_stores') }} s
left join {{ ref('dim_region') }} r
    on r.region = s.region
