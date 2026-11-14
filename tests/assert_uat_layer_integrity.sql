{{ config(severity='error') }}

-- UAT Layer Integrity Test
-- Ensures all silver and gold models have valid data and relationships
-- This test should PASS before promoting to PROD

with silver_counts as (
    select
        'slv_customers' as model_name,
        count(*) as row_count
    from {{ ref('slv_customers') }}
    
    union all
    
    select
        'slv_products' as model_name,
        count(*) as row_count
    from {{ ref('slv_products') }}
    
    union all
    
    select
        'slv_orders' as model_name,
        count(*) as row_count
    from {{ ref('slv_orders') }}
    
    union all
    
    select
        'slv_order_items' as model_name,
        count(*) as row_count
    from {{ ref('slv_order_items') }}
    
    union all
    
    select
        'slv_payments' as model_name,
        count(*) as row_count
    from {{ ref('slv_payments') }}
    
    union all
    
    select
        'slv_returns' as model_name,
        count(*) as row_count
    from {{ ref('slv_returns') }}
),

gold_counts as (
    select
        'dim_customers_scd2' as model_name,
        count(*) as row_count
    from {{ ref('dim_customers_scd2') }}
    
    union all
    
    select
        'dim_products' as model_name,
        count(*) as row_count
    from {{ ref('dim_products') }}
    
    union all
    
    select
        'dim_stores' as model_name,
        count(*) as row_count
    from {{ ref('dim_stores') }}
    
    union all
    
    select
        'fct_sales' as model_name,
        count(*) as row_count
    from {{ ref('fct_sales') }}
    
    union all
    
    select
        'fct_payments' as model_name,
        count(*) as row_count
    from {{ ref('fct_payments') }}
    
    union all
    
    select
        'fct_returns' as model_name,
        count(*) as row_count
    from {{ ref('fct_returns') }}
)

select *
from (
    select * from silver_counts
    union all
    select * from gold_counts
)
where row_count = 0