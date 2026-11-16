{{ config(materialized='table', tags=['gold', 'facts']) }}

{#
    Order-grain fact (production parity: fact_orders). One row per order,
    aggregating its lines: item count, quantity, gross/net amounts and the
    cost / profit / margin metrics from the line-level fact. customer_sk is
    resolved as-of the order date with the same SCD2 fallback as fct_sales.
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
    select store_id, region_sk, region from {{ ref('dim_stores') }}
),

customers_scd2 as (
    select * from {{ ref('dim_customers_scd2') }}
),

{{ log_step('line_metrics') }}

line_metrics as (
    select
        orders.order_id,
        orders.customer_id,
        orders.store_id,
        orders.order_date,
        orders.order_status,
        orders.channel,
        orders.discount_pct,
        cast(orders.total_amount as decimal(18, 2)) as booked_amount,
        items.quantity,
        items.line_total,
        cast(items.quantity * products.cost_price as decimal(18, 2)) as line_cost,
        cast(
            round(items.line_total * (1 - coalesce(orders.discount_pct, 0) / 100), 2)
            as decimal(18, 2)
        ) as line_net
    from orders
    join items
        on items.order_id = orders.order_id
    left join products
        on products.product_id = items.product_id
),

{{ log_step('aggregate') }}

aggregated as (
    select
        order_id,
        customer_id,
        store_id,
        order_date,
        order_status,
        channel,
        discount_pct,
        booked_amount,
        cast(count(*) as bigint)          as item_count,
        cast(sum(quantity) as bigint)     as total_quantity,
        cast(sum(line_total) as decimal(18, 2)) as gross_amount,
        cast(sum(line_net)   as decimal(18, 2)) as net_amount,
        cast(sum(line_cost)  as decimal(18, 2)) as cost_amount
    from line_metrics
    group by
        order_id, customer_id, store_id, order_date, order_status,
        channel, discount_pct, booked_amount
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
    a.order_id,
    coalesce(customers_scd2.customer_sk, first_version.customer_sk, 'UNKNOWN') as customer_sk,
    a.customer_id,
    a.store_id,
    stores.region_sk,
    stores.region,
    cast(date_format(a.order_date, 'yyyyMMdd') as int) as date_key,
    a.order_date,
    a.order_status,
    a.channel,
    a.discount_pct,
    a.booked_amount,
    a.item_count,
    a.total_quantity,
    a.gross_amount,
    a.net_amount,
    a.cost_amount,
    cast(a.net_amount - a.cost_amount as decimal(18, 2)) as profit_amount,
    cast(
        (a.net_amount - a.cost_amount) / nullif(a.net_amount, 0)
        as decimal(9, 4)
    ) as profit_margin
from aggregated a
left join stores
    on stores.store_id = a.store_id
left join customers_scd2
    on  customers_scd2.customer_id = a.customer_id
    and cast(a.order_date as timestamp) >= customers_scd2.valid_from
    and cast(a.order_date as timestamp) <  customers_scd2.valid_to
left join first_customer_version as first_version
    on first_version.customer_id = a.customer_id
