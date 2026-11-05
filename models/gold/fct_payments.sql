{{ config(materialized='table', tags=['gold', 'facts']) }}

{#
    Payment-attempt fact. One row per payment attempt (retries and split
    payments are valid and stay separate).
#}

with payments as (
    select * from {{ ref('slv_payments') }}
),

orders as (
    select * from {{ ref('slv_orders') }}
)

{{ log_step('join_orders') }}

select
    payments.payment_id,
    payments.order_id,
    orders.customer_id,
    orders.store_id,
    cast(date_format(payments.payment_date, 'yyyyMMdd') as int) as date_key,
    payments.payment_date,
    payments.payment_method,
    payments.payment_status,
    payments.amount,
    payments.transaction_ref,
    payments.payment_status = 'SUCCESS' as is_successful
from payments
left join orders
    on payments.order_id = orders.order_id
