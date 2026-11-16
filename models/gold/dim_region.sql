{{ config(materialized='table', tags=['gold', 'dimensions']) }}

{#
    Region dimension (production parity: dim_region). One row per region,
    conformed so facts and dim_stores can join on a surrogate key.
#}

{{ log_step('enrich') }}

with regions as (
    select
        upper(trim(region)) as region,
        count(*)            as store_count
    from {{ ref('slv_stores') }}
    where region is not null and region <> ''
    group by upper(trim(region))
)

select
    {{ surrogate_key(['region']) }} as region_sk,
    region,
    cast(store_count as bigint)     as store_count
from regions
