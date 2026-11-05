{{ config(materialized='table', tags=['silver', 'products']) }}

with bronze_products as (
    select * from {{ ref('stg_products') }}
),

{{ log_step('clean_types') }}

cleaned as (
    select
        trim(product_id) as product_id,
        trim(product_name) as product_name,
        trim(brand) as brand,
        coalesce(initcap(trim(category)), 'Unassigned') as category,
        cast(regexp_replace(unit_price, '[^0-9.]', '') as decimal(10,2)) as unit_price,
        cast(regexp_replace(cost_price, '[^0-9.]', '') as decimal(10,2)) as cost_price,
        upper(coalesce(trim(currency), 'INR')) as currency,
        case
            when lower(trim(is_active)) in ('1', 'true', 'y', 'yes') then true
            else false
        end as is_active,
        coalesce(
            try_to_date(created_date, 'yyyy-MM-dd'),
            try_to_date(created_date, 'dd-MM-yyyy'),
            try_to_date(created_date, 'dd/MM/yyyy')
        ) as created_date,
        row_number() over (partition by product_id order by created_date desc) as rn
    from bronze_products
    where product_id is not null
)

{{ log_step('final') }}

select
    product_id,
    product_name,
    brand,
    category,
    unit_price,
    cost_price,
    currency,
    is_active,
    created_date
from cleaned
where rn = 1

