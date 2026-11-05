{{ config(materialized='table', tags=['gold', 'dimensions']) }}

{#
    Conformed date dimension spanning the order history (plus a small buffer).
    Keeps reporting joins independent of fact-table date coverage.
#}

with bounds as (
    select
        coalesce(min(order_date), date '2025-01-01') as min_date,
        coalesce(max(order_date), date '2026-12-31') as max_date
    from {{ ref('slv_orders') }}
),

{{ log_step('build_spine') }}

spine as (
    select explode(sequence(min_date, max_date, interval 1 day)) as date_day
    from bounds
)

{{ log_step('final') }}

select
    cast(date_format(date_day, 'yyyyMMdd') as int) as date_key,
    date_day,
    year(date_day)                                 as year,
    quarter(date_day)                              as quarter,
    month(date_day)                                as month,
    date_format(date_day, 'MMMM')                  as month_name,
    weekofyear(date_day)                           as week_of_year,
    dayofweek(date_day)                            as day_of_week,
    date_format(date_day, 'EEEE')                  as day_name,
    dayofweek(date_day) in (1, 7)                  as is_weekend
from spine
