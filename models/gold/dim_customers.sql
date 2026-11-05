{{ config(materialized='table', tags=['gold', 'marts']) }}

{{ log_step('select_current') }}

select
    customer_id,
    first_name,
    last_name,
    concat(first_name, ' ', last_name) as full_name,
    email,
    phone,
    city,
    state,
    country,
    signup_date,
    customer_segment
from {{ ref('slv_customers') }}

