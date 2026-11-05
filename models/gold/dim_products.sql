{{ config(materialized='table', tags=['gold', 'marts']) }}

{{ log_step('enrich') }}

select
    product_id,
    product_name,
    brand,
    category,
    unit_price,
    cost_price,
    round(unit_price - cost_price, 2) as margin_amount,
    currency,
    is_active,
    created_date
from {{ ref('slv_products') }}

