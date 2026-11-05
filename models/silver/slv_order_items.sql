{{ config(materialized='table', tags=['silver', 'order_items']) }}

with bronze_items as (
    select * from {{ ref('stg_order_items') }}
),

{{ log_step('clean_types') }}

cleaned as (
    select
        order_item_id,
        order_id,
        product_id,
        case
            when lower(trim(quantity)) = 'one' then 1
            when lower(trim(quantity)) = 'two' then 2
            when lower(trim(quantity)) = 'three' then 3
            when lower(trim(quantity)) = 'four' then 4
            when lower(trim(quantity)) = 'five' then 5
            else coalesce(try_cast(regexp_extract(quantity, '([0-9]+)', 1) as int), try_cast(quantity as int), 1)
        end as quantity,
        cast(regexp_replace(unit_price, '[^0-9.]', '') as decimal(10,2)) as unit_price,
        cast(regexp_replace(line_total, '[^0-9.]', '') as decimal(10,2)) as line_total,
        row_number() over (partition by order_item_id order by order_id) as rn
    from bronze_items
    where order_item_id is not null
)

{{ log_step('final') }}

select
    order_item_id,
    order_id,
    product_id,
    quantity,
    unit_price,
    line_total
from cleaned
where rn = 1
