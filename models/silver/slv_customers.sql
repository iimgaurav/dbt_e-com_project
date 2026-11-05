{{ config(materialized="table", tags=["silver", "customers"]) }}

with
    bronze_customers as (select * from {{ ref("stg_customers") }}),

    {{ log_step('rank_latest') }}

    ranked as (
        select
            customer_id,
            trim(first_name) as first_name,
            trim(last_name) as last_name,
            lower(trim(email)) as email,
            trim(phone) as phone,
            trim(city) as city,
            upper(trim(state)) as state,
            upper(trim(country)) as country,
            coalesce(
                try_to_date(signup_date, 'yyyy-MM-dd'),
                try_to_date(signup_date, 'dd-MM-yyyy'),
                try_to_date(signup_date, 'dd/MM/yyyy')
            ) as signup_date,
            upper(trim(customer_segment)) as customer_segment,
            updated_at,
            row_number() over (partition by customer_id order by updated_at desc) as rn
        from bronze_customers
        where customer_id is not null
    )

{{ log_step('final') }}

select
    customer_id,
    first_name,
    last_name,
    email,
    phone,
    city,
    state,
    country,
    signup_date,
    customer_segment
from ranked
where rn = 1
