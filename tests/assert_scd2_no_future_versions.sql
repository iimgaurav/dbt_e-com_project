{{ config(severity='warn') }}

-- Data-quality signal (not a structural invariant): source rows whose updated_at
-- is in the future. The practice dataset intentionally contains a few of these,
-- so this warns instead of failing the build.
select
    customer_id,
    version_number,
    valid_from
from {{ ref('dim_customers_scd2') }}
where valid_from > current_timestamp()
