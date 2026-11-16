{{ config(materialized='table', tags=['gold', 'facts']) }}

{#
    Order-line fact.
    - customer_sk is resolved as-of the order date against the SCD2 dimension;
      orders that predate the customer's first observed version fall back to
      that earliest version (never to a wrong later state).
    - Cost / profit / margin mirror the production fact_sales definition:
        cost_amount   = quantity * product.cost_price
        profit_amount = net_amount - cost_amount
        profit_margin = profit_amount / net_amount
      A missing product (orphan line) yields NULL cost/profit rather than a
      silently zero-cost profit.
    - region_sk is resolved through dim_stores so regional reporting can join
      dim_region directly.
#}

with orders as (
    select * from {{ ref('slv_orders') }}
),

items as (
    select * from {{ ref('slv_order_items') }}
),

products as (
    select product_id, cost_price from {{ ref('slv_products') }}
),

stores as (
    select store_id, region_sk from {{ ref('dim_stores') }}
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
),

{{ log_step('line_metrics') }}

line_metrics as (
    select
        items.order_item_id,
        orders.order_id,
        orders.customer_id,
        items.product_id,
        orders.store_id,
        orders.order_date,
        orders.order_status,
        orders.channel,
        items.quantity,
        items.unit_price,
        items.line_total,
        orders.discount_pct,
        cast(
            round(items.line_total * (1 - coalesce(orders.discount_pct, 0) / 100), 2)
            as decimal(18, 2)
        ) as net_amount,
        cast(items.quantity * products.cost_price as decimal(18, 2)) as cost_amount
    from items
    join orders
        on items.order_id = orders.order_id
    left join products
        on products.product_id = items.product_id
)

{{ log_step('as_of_join') }}

select
    lm.order_item_id,
    lm.order_id,
    coalesce(customers_scd2.customer_sk, first_version.customer_sk, 'UNKNOWN') as customer_sk,
    lm.customer_id,
    lm.product_id,
    lm.store_id,
    stores.region_sk,
    cast(date_format(lm.order_date, 'yyyyMMdd') as int) as date_key,
    lm.order_date,
    lm.order_status,
    lm.channel,
    lm.quantity,
    lm.unit_price,
    lm.line_total,
    lm.discount_pct,
    lm.net_amount,
    lm.cost_amount,
    cast(lm.net_amount - lm.cost_amount as decimal(18, 2)) as profit_amount,
    cast(
        (lm.net_amount - lm.cost_amount) / nullif(lm.net_amount, 0)
        as decimal(9, 4)
    ) as profit_margin
from line_metrics lm
left join stores
    on stores.store_id = lm.store_id
left join customers_scd2
    on  customers_scd2.customer_id = lm.customer_id
    and cast(lm.order_date as timestamp) >= customers_scd2.valid_from
    and cast(lm.order_date as timestamp) <  customers_scd2.valid_to
left join first_customer_version as first_version
    on first_version.customer_id = lm.customer_id
