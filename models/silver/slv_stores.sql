{{ config(materialized='table', tags=['silver', 'stores']) }}

with bronze_stores as (
    select * from {{ ref('stg_stores') }}
),

{{ log_step('clean_types') }}

cleaned as (
    select
        trim(store_id) as store_id,
        trim(store_name) as store_name,
        trim(city) as city,
        upper(trim(region)) as region,
        coalesce(
            try_to_date(opened_date, 'yyyy-MM-dd'),
            try_to_date(opened_date, 'dd-MM-yyyy'),
            try_to_date(opened_date, 'dd/MM/yyyy')
        ) as opened_date,
        row_number() over (partition by store_id order by store_name) as rn
    from bronze_stores
    where store_id is not null
)

{{ log_step('final') }}

select
    store_id,
    store_name,
    city,
    region,
    opened_date
from cleaned
where rn = 1
