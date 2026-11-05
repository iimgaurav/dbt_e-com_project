{{ config(materialized='table', tags=['gold', 'facts']) }}

{#
    Returns fact at return-line grain, enriched with the originating order line.
#}

with returns as (
    select * from {{ ref('slv_returns') }}
),

items as (
    select * from {{ ref('slv_order_items') }}
),

orders as (
    select * from {{ ref('slv_orders') }}
)

{{ log_step('join_lines') }}

select
    returns.return_id,
    returns.order_item_id,
    items.order_id,
    items.product_id,
    orders.customer_id,
    orders.store_id,
    cast(date_format(returns.return_date, 'yyyyMMdd') as int) as date_key,
    returns.return_date,
    returns.reason,
    returns.refund_amount,
    items.line_total,
    returns.refund_amount > items.line_total as is_refund_above_line_total
from returns
left join items
    on returns.order_item_id = items.order_item_id
left join orders
    on items.order_id = orders.order_id
