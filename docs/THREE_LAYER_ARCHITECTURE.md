# Three-Layer Architecture Guide

## Overview

This document describes the three-layer environment architecture for the sales_analytics dbt project, designed to ensure quality and safety across development, testing, and production environments.

## Layer Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        DEVELOPMENT (DEV)                            │
│  Catalog: dbt | Schema: dev | Threads: 4                            │
│  Purpose: Continuous integration, rapid feedback                    │
│  Trigger: Pull Request to main                                      │
│  Gate: Required PR check "dev build (PR)"                          │
└─────────────────────────────┬───────────────────────────────────────┘
                              │ DEV passes
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      USER ACCEPTANCE (UAT)                          │
│  Catalog: dbt_uat | Schema: uat | Threads: 4                        │
│  Purpose: User acceptance testing, sandbox validation               │
│  Trigger: Manual dispatch after DEV passes                          │
│  Gate: GitHub environment "uat" (approver-based)                   │
└─────────────────────────────┬───────────────────────────────────────┘
                              │ UAT passes + approval
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        PRODUCTION (PROD)                            │
│  Catalog: dbt_prod | Schema: analytics | Threads: 8                 │
│  Purpose: Live production deployment                                │
│  Trigger: Push to main (after UAT approval)                        │
│  Gate: GitHub environment "production" (required reviewers)        │
└─────────────────────────────────────────────────────────────────────┘
```

## Environment Details

### Layer 1: DEV (Development)
- **Catalog**: `dbt`
- **Schema**: `dev`
- **Threads**: 4
- **Purpose**: Continuous integration, rapid feedback for developers
- **Trigger**: Pull Request to main branch
- **Quality Gate**: No errors/fails, warnings ≤ 5
- **Artifacts**: 14-day retention

### Layer 2: UAT (User Acceptance Testing)
- **Catalog**: `dbt_uat`
- **Schema**: `uat`
- **Threads**: 4
- **Purpose**: User acceptance testing, sandbox validation
- **Trigger**: Manual workflow dispatch after DEV passes
- **Quality Gate**: No errors/fails, warnings ≤ 5
- **Artifacts**: 14-day retention
- **Special Features**: Full refresh option available

### Layer 3: PROD (Production)
- **Catalog**: `dbt_prod`
- **Schema**: `analytics`
- **Threads**: 8
- **Purpose**: Live production deployment
- **Trigger**: Push to main (after UAT approval)
- **Quality Gate**: No errors/fails, warnings ≤ 5
- **Artifacts**: 30-day retention
- **Special Features**: Full refresh option, emergency deploy

## Promotion Flow

### Standard Promotion
1. **Developer** creates PR → DEV layer runs automatically
2. **DEV passes** → UAT layer available for manual trigger
3. **UAT passes** → PROD deployment available (requires approval)
4. **PROD deploys** → Live production update

### Emergency Promotion
For critical fixes, use emergency deploy:
- Skips UAT layer
- Requires explicit approval
- Only available via workflow_dispatch with skip_uat=true

## Quality Gates

All layers enforce the same quality gate:
- **No errors or fails**: Any result with status `error` or `fail` fails the build
- **Warning ceiling**: Warnings cannot exceed baseline of 5
- **Warning improvement**: If warnings < 5, annotation suggests lowering baseline

## Test Cases by Layer

### DEV Layer Tests
- All schema tests (staging, silver, gold)
- All singular tests (SCD2 invariants)
- Layer integrity tests
- **Expected**: 5 warnings (documented data quality issues)

### UAT Layer Tests
- All DEV tests
- Additional UAT-specific validation
- Full refresh validation
- Performance benchmarks
- **Expected**: 5 warnings

### PROD Layer Tests
- All UAT tests
- Production-specific validation
- Referential integrity checks
- Data volume validation
- **Expected**: 5 warnings

## CI/CD Pipeline Files

| File | Purpose |
|------|---------|
| `.github/workflows/dbt_pipeline.yml` | Unified 3-layer pipeline |
| `.github/workflows/dbt_ci.yml` | DEV-only CI (legacy) |
| `.github/workflows/dbt_deploy.yml` | PROD-only deploy (legacy) |
| `.github/workflows/dbt_uat.yml` | UAT-only deploy (legacy) |
| `.github/workflows/codeql.yml` | Code security scanning |

## GitHub Environments

### dev
- No protection rules
- Automatic runs on PR
- Repository secrets

### uat
- Optional reviewers
- Manual trigger required
- Environment-specific variables

### production
- Required reviewers (4 engineers)
- Optional wait timer
- Environment-scoped secrets
- Deployment protection rules

## Artifact Retention

| Environment | Retention | Contents |
|-------------|----------|----------|
| DEV | 14 days | manifest.json, run_results.json, catalog.json, logs/ |
| UAT | 14 days | manifest.json, run_results.json, catalog.json, logs/ |
| PROD | 30 days | manifest.json, run_results.json, catalog.json, logs/ |

## Rollback Strategy

### DEV
- Automatic rollback on PR failure
- No data impact (isolated catalog)

### UAT
- Manual rollback via full refresh
- Isolated catalog (no PROD impact)

### PROD
- Revert SQL + rebuild
- Full refresh for incremental models
- Bundle redeploy from previous commit

## Monitoring

### Quality Metrics
- Warning count tracking
- Test pass/fail rates
- Build duration trends

### Alerting
- Email notifications on failure
- GitHub status checks
- Artifact availability

## Best Practices

1. **Always test in DEV first**: Never skip the DEV layer
2. **UAT requires approval**: Human validation before PROD
3. **Quality gates are mandatory**: No exceptions for warnings
4. **Artifacts are evidence**: Keep for debugging
5. **Rollback is a rebuild**: dbt is declarative, not a restore

## Troubleshooting

### DEV Failures
- Check schema.yml for test failures
- Review quarantine_records table
- Verify raw data availability

### UAT Failures
- Compare DEV vs UAT results
- Check environment-specific variables
- Verify UAT catalog exists

### PROD Failures
- Check approval status
- Verify PROD catalog exists
- Review production permissions
- Check warehouse availability