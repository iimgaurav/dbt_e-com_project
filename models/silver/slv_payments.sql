{{ config(materialized='table', tags=['silver', 'payments']) }}

{%- set method_map = {
    'upi': 'UPI',
    'cc': 'CREDIT CARD',
    'credit card': 'CREDIT CARD',
    'credit_card': 'CREDIT CARD',
    'dc': 'DEBIT CARD',
    'debit card': 'DEBIT CARD',
    'debit_card': 'DEBIT CARD',
    'cod': 'COD',
    'cash on delivery': 'COD',
    'net banking': 'NET BANKING',
    'netbanking': 'NET BANKING',
    'wallet': 'WALLET'
} -%}

{%- set status_map = {
    'success': 'SUCCESS',
    'succeeded': 'SUCCESS',
    'failed': 'FAILED',
    'pending': 'PENDING',
    'refunded': 'REFUNDED'
} -%}

with bronze_payments as (
    select * from {{ ref('stg_payments') }}
),

{{ log_step('map_values') }}

cleaned as (
    select
        trim(payment_id)                                  as payment_id,
        trim(order_id)                                    as order_id,
        {{ parse_date('payment_date') }}                  as payment_date,
        {{ map_values('payment_method', method_map) }}    as payment_method,
        {{ clean_amount('amount') }}                      as amount,
        {{ map_values('payment_status', status_map) }}    as payment_status,
        nullif(trim(transaction_ref), '')                 as transaction_ref,
        row_number() over (
            partition by payment_id order by _ingest_ts desc
        ) as rn
    from bronze_payments
    where payment_id is not null
)

{{ log_step('final') }}

select
    payment_id,
    order_id,
    payment_date,
    payment_method,
    amount,
    payment_status,
    transaction_ref
from cleaned
where rn = 1
