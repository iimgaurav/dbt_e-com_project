# Test Cases Documentation

## Overview

This document outlines all test cases for the sales_analytics dbt project across all three environments (DEV, UAT, PROD).

## Test Categories

### 1. Schema Tests (Generic Tests)

#### Staging Layer (Bronze)
- **not_null**: customer_id, product_id, order_id, store_id, payment_id, return_id
- **Severity**: Warning (bronze intentionally preserves dirty data)

#### Silver Layer (Cleaned)
- **not_null**: All business keys after cleaning
- **unique**: Business keys after deduplication
- **relationships**: Foreign key relationships validated

#### Gold Layer (Analytics)
- **not_null**: All dimension keys
- **unique**: Surrogate keys in dimensions
- **relationships**: Fact-to-dimension relationships
- **accepted_values**: Status codes, categories, etc.

### 2. Singular Tests (Custom Tests)

#### SCD2 Invariant Tests
1. **assert_scd2_no_future_versions**: No future-dated versions in dim_customers_scd2
2. **assert_scd2_no_gaps_or_overlaps**: No gaps or overlaps in SCD2 validity periods
3. **assert_scd2_one_current_per_customer**: Exactly one current version per customer
4. **assert_scd2_valid_range**: Valid from < valid to for all versions

#### Layer Integrity Tests
5. **assert_dev_layer_integrity**: All staging models have valid row counts
6. **assert_uat_layer_integrity**: All silver/gold models have valid data
7. **assert_prod_layer_integrity**: No orphaned records in production

### 3. Data Quality Tests

#### Bronze Layer Quality
- Row count validation (no empty tables)
- Source file tracking (_source_file populated)
- Ingest timestamp validation (_ingest_ts populated)

#### Silver Layer Quality
- Deduplication validation (no exact duplicates)
- Type casting validation (all columns properly typed)
- Standardization validation (canonical values)
- Quarantine validation (bad rows properly quarantined)

#### Gold Layer Quality
- SCD2 validity (no gaps/overlaps)
- Referential integrity (no orphaned records)
- Aggregation accuracy (fact totals match source)
- Dimension completeness (all expected dimensions populated)

## Test Execution by Environment

### DEV Environment (Layer 1)
**Trigger**: PR to main
**Tests Run**:
- All schema tests (severity: warn for bronze, error for silver/gold)
- All singular tests
- Layer integrity tests
**Expected Warnings**: 6 (5 original + 1 new prod layer integrity check)
**Quality Gate**: No errors/fails, warnings ≤ 5

### UAT Environment (Layer 2)
**Trigger**: Manual dispatch after DEV passes
**Tests Run**:
- All DEV tests
- Additional UAT-specific tests
- Full refresh validation
- Performance benchmarks
**Expected Warnings**: 5
**Quality Gate**: No errors/fails, warnings ≤ 5

### PROD Environment (Layer 3)
**Trigger**: Push to main (after UAT approval)
**Tests Run**:
- All UAT tests
- Production-specific validation
- Referential integrity checks
- Data volume validation
**Expected Warnings**: 5
**Quality Gate**: No errors/fails, warnings ≤ 5

## Test Results Summary

### Baseline Run (DEV)
```
27 success   (26 models + 1 snapshot)
66 pass      (tests)
5 warn       (tests - expected, documented)
```

### Accepted Warnings (5 total)
1. `accepted_values_slv_orders_order_status__...`
2. `assert_scd2_no_future_versions`
3. `relationships_fct_payments_order_id__...`
4. `relationships_fct_returns_order_item_id__...`
5. `relationships_fct_sales_product_id__...`

## Running Tests Locally

### DEV
```bash
dbt build --profiles-dir . --target dev
dbt test --profiles-dir . --target dev
```

### UAT
```bash
dbt build --profiles-dir . --target uat
dbt test --profiles-dir . --target uat
```

### PROD
```bash
dbt build --profiles-dir . --target prod
dbt test --profiles-dir . --target prod
```

## Test Maintenance

### Adding New Tests
1. Add to appropriate schema.yml
2. Create singular test in tests/ directory
3. Update this documentation
4. Update EXPECTED_WARNINGS if new warnings introduced

### Updating Baseline
When fixing warnings:
1. Lower EXPECTED_WARNINGS in both workflows
2. Document the fix in DATA_QUALITY.md
3. Update this document

## CI/CD Integration

All tests are automatically run in the 3-layer pipeline:
- **Layer 1 (DEV)**: Runs on every PR
- **Layer 2 (UAT)**: Runs after DEV passes (manual trigger)
- **Layer 3 (PROD)**: Runs after UAT approval (push to main)

Quality gates ensure no regressions are promoted between layers.