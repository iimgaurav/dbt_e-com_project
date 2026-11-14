# CI/CD Pipeline Guide - Three-Layer Architecture

## Quick Start

### Trigger DEV Build
```bash
# Automatic on PR to main
# Or manual:
gh workflow run dbt_pipeline.yml -f environment=dev
```

### Trigger UAT Build
```bash
# After DEV passes:
gh workflow run dbt_pipeline.yml -f environment=uat
```

### Trigger PROD Deploy
```bash
# After UAT passes and approved:
gh workflow run dbt_pipeline.yml -f environment=prod
```

## Pipeline Stages

### Stage 1: DEV (Continuous Integration)
- **Trigger**: PR to main or manual dispatch with environment=dev
- **Duration**: ~15-30 minutes
- **Steps**:
  1. Checkout code
  2. Setup dbt Fusion (pinned v2.0.11)
  3. Install dependencies (dbt deps)
  4. Parse project (dbt parse)
  5. Debug connection (dbt debug)
  6. Build DEV (dbt build --target dev)
  7. Run tests (dbt test --target dev)
  8. Quality gate (warnings ≤ 5)
  9. Upload artifacts

### Stage 2: UAT (User Acceptance Testing)
- **Trigger**: Manual dispatch after DEV passes
- **Duration**: ~15-30 minutes
- **Steps**:
  1. Checkout code
  2. Setup dbt Fusion
  3. Install dependencies
  4. Parse project
  5. Debug connection
  6. Build UAT (with optional full refresh)
  7. Run tests
  8. Quality gate
  9. Upload artifacts

### Stage 3: PROD (Production Deployment)
- **Trigger**: Push to main or manual dispatch with environment=prod
- **Duration**: ~20-40 minutes
- **Steps**:
  1. Checkout code
  2. Setup dbt Fusion
  3. Install dependencies
  4. Parse project
  5. Debug connection
  6. Deploy to PROD (with optional full refresh)
  7. Run tests
  8. Quality gate
  9. Upload artifacts

## Environment Variables

### Required Secrets (Repository Level)
| Secret | Value |
|--------|-------|
| `DATABRICKS_HOST` | https://dbc-f49d67a0-6a22.cloud.databricks.com |
| `DATABRICKS_HTTP_PATH` | /sql/1.0/warehouses/faced73bbff7e9f2 |
| `DATABRICKS_TOKEN` | Service principal PAT |

### Environment Variables (per environment)
| Variable | DEV | UAT | PROD |
|----------|-----|-----|------|
| `DBT_DEV_CATALOG` | dbt | - | - |
| `DBT_DEV_SCHEMA` | dev | - | - |
| `DBT_UAT_CATALOG` | - | dbt_uat | - |
| `DBT_UAT_SCHEMA` | - | uat | - |
| `DBT_PROD_CATALOG` | - | - | dbt_prod |
| `DBT_PROD_SCHEMA` | - | - | analytics |

## Quality Gate Details

### Pass Criteria
- Zero errors or fails
- Warnings ≤ 5 (baseline)
- All tests pass

### Fail Criteria
- Any error or fail status
- Warnings > 5
- Missing artifacts

### Warning Tracking
The 5 accepted warnings are documented in DATA_QUALITY.md:
1. `accepted_values_slv_orders_order_status__...`
2. `assert_scd2_no_future_versions`
3. `relationships_fct_payments_order_id__...`
4. `relationships_fct_returns_order_item_id__...`
5. `relationships_fct_sales_product_id__...`

## Emergency Procedures

### Emergency PROD Deploy (Skip UAT)
```bash
gh workflow run dbt_pipeline.yml \
  -f environment=prod \
  -f skip_uat=true
```
**Warning**: Requires explicit approval, use only for critical fixes.

### Full Refresh
```bash
gh workflow run dbt_pipeline.yml \
  -f environment=prod \
  -f full_refresh=true
```
**Note**: Rebuilds incremental models from scratch.

## Monitoring and Alerts

### GitHub Status Checks
- `dev build (PR)`: Required for PR merge
- `uat build`: Manual trigger status
- `prod deploy`: Production deployment status

### Artifacts
- Download from GitHub Actions run page
- Retention: 14 days (DEV/UAT), 30 days (PROD)

### Email Notifications
- On failure: k.gaurav653@gmail.com
- Configured in resources/dbt_job.yml

## Best Practices

1. **Always start with DEV**: Never skip to UAT or PROD
2. **Review warnings**: Understand before promoting
3. **Keep artifacts**: Download for debugging
4. **Use full refresh wisely**: Only when needed
5. **Document changes**: Update DATA_QUALITY.md for new warnings

## Troubleshooting

### Pipeline Stuck
- Check GitHub environment approval status
- Verify secrets are configured
- Review workflow logs

### Quality Gate Failures
- Review run_results.json artifact
- Check specific test failures
- Update EXPECTED_WARNINGS if needed

### Connection Issues
- Verify Databricks secrets
- Check warehouse availability
- Test with dbt debug locally

## Related Documentation
- [THREE_LAYER_ARCHITECTURE.md](THREE_LAYER_ARCHITECTURE.md)
- [TEST_CASES.md](TEST_CASES.md)
- [CI_CD.md](CI_CD.md)
- [DEPLOYMENT.md](DEPLOYMENT.md)
- [RUNBOOK.md](RUNBOOK.md)