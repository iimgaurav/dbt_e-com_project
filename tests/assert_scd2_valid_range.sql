-- Structural invariant: a version must end after it starts.
select
    customer_sk,
    customer_id,
    version_number,
    valid_from,
    valid_to
from {{ ref('dim_customers_scd2') }}
where valid_to <= valid_from
