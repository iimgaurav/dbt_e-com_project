{{ config(severity='warn') }}

-- PROD Layer Integrity Test
-- Ensures production data has valid relationships and no orphaned records
-- This test should PASS before final deployment

with orphaned_orders as (
    select count(*) as orphan_count
    from {{ ref('fct_sales') }} f
    left join {{ ref('dim_customers_scd2') }} c
        on f.customer_id = c.customer_id
    where c.customer_id is null
),

orphaned_products as (
    select count(*) as orphan_count
    from {{ ref('fct_sales') }} f
    left join {{ ref('dim_products') }} p
        on f.product_id = p.product_id
    where p.product_id is null
),

orphaned_payments as (
    select count(*) as orphan_count
    from {{ ref('fct_payments') }} f
    left join {{ ref('fct_sales') }} s
        on f.order_id = s.order_id
    where s.order_id is null
),

orphaned_returns as (
    select count(*) as orphan_count
    from {{ ref('fct_returns') }} f
    left join {{ ref('fct_sales') }} s
        on f.order_item_id = s.order_item_id
    where s.order_item_id is null
)

select 'orphaned_orders' as test_name, orphan_count from orphaned_orders where orphan_count > 0
union all
select 'orphaned_products' as test_name, orphan_count from orphaned_products where orphan_count > 0
union all
select 'orphaned_payments' as test_name, orphan_count from orphaned_payments where orphan_count > 0
union all
select 'orphaned_returns' as test_name, orphan_count from orphaned_returns where orphan_count > 0