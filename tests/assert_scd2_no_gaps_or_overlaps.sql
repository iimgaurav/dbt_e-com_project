-- Validity windows must be contiguous: valid_to of version N = valid_from of N+1.
select
    a.customer_id,
    a.version_number,
    a.valid_to,
    b.valid_from as next_valid_from
from {{ ref('dim_customers_scd2') }} a
join {{ ref('dim_customers_scd2') }} b
    on  a.customer_id = b.customer_id
    and b.version_number = a.version_number + 1
where a.valid_to <> b.valid_from
