{{ config(materialized='table', tags=['gold', 'facts']) }}

{#
    Order-line fact. customer_sk is resolved as-of the order date against the
    SCD2 dimension; orders that predate the customer's first observed version
    fall back to that earliest version (never to a wrong later state).
#}

with orders as (
    select * from {{ ref('slv_orders') }}
),

items as (
    select * from {{ ref('slv_order_items') }}
),

customers_scd2 as (
    select * from {{ ref('dim_customers_scd2') }}
),

{{ log_step('first_version') }}

first_customer_version as (
    select customer_id, customer_sk
    from (
        select
            customer_id,
            customer_sk,
            row_number() over (partition by customer_id order by valid_from) as rn
        from customers_scd2
    ) _
    where rn = 1
)

{{ log_step('as_of_join') }}

select
    items.order_item_id,
    orders.order_id,
    coalesce(customers_scd2.customer_sk, first_version.customer_sk, 'UNKNOWN') as customer_sk,
    orders.customer_id,
    items.product_id,
    orders.store_id,
    cast(date_format(orders.order_date, 'yyyyMMdd') as int) as date_key,
    orders.order_date,
    orders.order_status,
    orders.channel,
    items.quantity,
    items.unit_price,
    items.line_total,
    orders.discount_pct,
    round(items.line_total * (1 - coalesce(orders.discount_pct, 0) / 100), 2) as net_amount
from items
join orders
    on items.order_id = orders.order_id
left join customers_scd2
    on  customers_scd2.customer_id = orders.customer_id
    and cast(orders.order_date as timestamp) >= customers_scd2.valid_from
    and cast(orders.order_date as timestamp) <  customers_scd2.valid_to
left join first_customer_version as first_version
    on first_version.customer_id = orders.customer_id
