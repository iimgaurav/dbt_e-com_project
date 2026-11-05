{{ config(materialized='table', tags=['silver', 'quality']) }}

{#
    Data-quality quarantine: every row that violates an invariant is recorded
    here with a reject_reason instead of being silently dropped downstream.
    A row can appear once per failed rule (long format) - join on record_id.
#}

with orders as (select * from {{ ref('slv_orders') }}),
customers as (select customer_id from {{ ref('slv_customers') }}),
stores as (select store_id from {{ ref('slv_stores') }}),
items as (select * from {{ ref('slv_order_items') }}),
products as (select product_id from {{ ref('slv_products') }}),
payments as (select * from {{ ref('slv_payments') }}),
returns as (select * from {{ ref('slv_returns') }}),

{{ log_step('evaluate_rules', detail='17 rules') }}

checks as (

    -- orders
    select 'orders' as source_table, order_id as record_id,
           'missing_customer_id' as reject_reason
    from orders where customer_id is null

    union all
    select 'orders', order_id, 'orphan_customer_id'
    from orders o
    where o.customer_id is not null
      and not exists (select 1 from customers c where c.customer_id = o.customer_id)

    union all
    select 'orders', order_id, 'order_date_in_future'
    from orders where order_date > current_date()

    union all
    select 'orders', order_id, 'discount_out_of_range'
    from orders where discount_pct < 0 or discount_pct > 100

    union all
    select 'orders', order_id, 'unknown_store_id'
    from orders o
    where o.store_id is not null
      and not exists (select 1 from stores s where s.store_id = o.store_id)

    union all
    select 'orders', order_id, 'missing_channel'
    from orders where channel is null or channel = 'UNKNOWN'

    -- order items
    union all
    select 'order_items', order_item_id, 'non_positive_quantity'
    from items where quantity is null or quantity <= 0

    union all
    select 'order_items', order_item_id, 'missing_unit_price'
    from items where unit_price is null

    union all
    select 'order_items', order_item_id, 'orphan_order_id'
    from items i
    where not exists (select 1 from orders o where o.order_id = i.order_id)

    union all
    select 'order_items', order_item_id, 'orphan_product_id'
    from items i
    where not exists (select 1 from products p where p.product_id = i.product_id)

    union all
    select 'order_items', order_item_id, 'line_total_mismatch'
    from items
    where unit_price is not null and quantity is not null
      and abs(line_total - quantity * unit_price) > 0.01

    -- payments
    union all
    select 'payments', payment_id, 'missing_amount'
    from payments where amount is null

    union all
    select 'payments', payment_id, 'orphan_order_id'
    from payments p
    where not exists (select 1 from orders o where o.order_id = p.order_id)

    union all
    select 'payments', payment_id, 'payment_before_order'
    from payments p
    join orders o on p.order_id = o.order_id
    where p.payment_date < o.order_date

    -- returns
    union all
    select 'returns', return_id, 'orphan_order_item_id'
    from returns r
    where not exists (select 1 from items i where i.order_item_id = r.order_item_id)

    union all
    select 'returns', return_id, 'refund_above_line_total'
    from returns r
    join items i on r.order_item_id = i.order_item_id
    where r.refund_amount > i.line_total

    union all
    select 'returns', return_id, 'return_before_order'
    from returns r
    join items i on r.order_item_id = i.order_item_id
    join orders o on i.order_id = o.order_id
    where r.return_date < o.order_date
)

{{ log_step('final') }}

select
    source_table,
    record_id,
    reject_reason,
    current_timestamp() as detected_at
from checks
