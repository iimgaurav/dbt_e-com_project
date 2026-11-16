{{ config(materialized='table', tags=['gold', 'dimensions']) }}

{#
    Conformed date dimension spanning the order history (plus a small buffer).
    Keeps reporting joins independent of fact-table date coverage.

    Fiscal calendar follows the production definition: the fiscal year runs
    1 July - 30 June, so July 2025 opens FY2026. is_holiday covers the three
    fixed-date Indian national holidays plus any dates listed in the
    `holiday_dates` var (list of 'yyyy-MM-dd' strings; override per env).
#}

{%- set extra_holidays = var('holiday_dates', []) -%}

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
    dayofweek(date_day) in (1, 7)                  as is_weekend,
    -- fiscal calendar: FY runs 1 July - 30 June
    case
        when month(date_day) >= 7 then year(date_day) + 1
        else year(date_day)
    end                                            as fiscal_year,
    case
        when month(date_day) between 7 and 9   then 1
        when month(date_day) between 10 and 12 then 2
        when month(date_day) between 1 and 3   then 3
        else 4
    end                                            as fiscal_quarter,
    -- holidays: fixed-date national holidays + configurable extra dates
    case
        when month(date_day) = 1  and day(date_day) = 26 then true
        when month(date_day) = 8  and day(date_day) = 15 then true
        when month(date_day) = 10 and day(date_day) = 2  then true
        when false{% for h in extra_holidays %} or date_day = date '{{ h }}'{% endfor %} then true
        else false
    end                                            as is_holiday,
    date_format(date_day, 'EEE')                   as day_abbr,
    date_format(date_day, 'MMM')                   as month_abbr,
    date_format(date_day, 'yyyy-MM')               as year_month,
    concat(cast(year(date_day) as string), '-Q', cast(quarter(date_day) as string)) as year_quarter
from spine
