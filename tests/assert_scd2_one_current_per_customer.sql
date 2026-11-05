-- Exactly one open (is_current) version per customer.
select
    customer_id,
    count(*) as current_versions
from {{ ref('dim_customers_scd2') }}
where is_current
group by customer_id
having count(*) <> 1
