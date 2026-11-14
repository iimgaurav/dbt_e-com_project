# Sales Analytics Project - Instructions Guide

## Project Overview

This is a production dbt project for retail sales analytics, built with **dbt Fusion** on **Databricks Unity Catalog**. The project follows a medallion architecture (bronze → silver → gold) to process a deliberately dirty practice dataset.

### Key Features
- **Unity Catalog Integration**: Uses Databricks Unity Catalog for catalog management
- **Medallion Architecture**: Raw → Bronze (ingestion) → Silver (cleaning) → Gold (analytics)
- **CI/CD Pipeline**: Automated testing and deployment via GitHub Actions
- **Local Development**: Scheduler dashboard for local development and testing
- **Data Quality**: Built-in quality checks with quarantine tables for bad data

## Architecture at a Glance

```
┌──────────────────────────────┐
│ UC volume (CSV files)        │  /Volumes/dbt/raw/sales_analytics_raw
└──────────────┬───────────────┘
               │ read_files(format => 'csv', inferColumnTypes => false)
┌──────────────▼───────────────┐
│ BRONZE  dbt.bronze.stg_*     │  all columns STRING + _ingest_ts, _source_file
└──────────────┬───────────────┘
               │ parse / clean / dedupe / map values
┌──────────────▼───────────────┐
│ SILVER  dbt.silver.slv_*     │  typed, canonical, deduped
│         quarantine_records   │  rows that violate an invariant
└──────────────┬───────────────┘
               │ conform + as-of SCD2 joins
┌──────────────▼───────────────┐
│ GOLD    dbt.gold.dim_*       │  star schema for BI
│         dbt.gold.fct_*       │
└──────────────────────────────┘
```

## Repository Structure

```
sales_analytics/
├── dbt_project.yml               # Project configuration
├── profiles.yml                  # Environment-aware profiles (dev/prod)
├── databricks.yml                # Asset Bundle deployment config
├── models/
│   ├── staging/                  # Bronze: 7 stg_* models
│   ├── silver/                   # 7 slv_* models + quarantine_records
│   ├── gold/                     # 5 dim_* + 3 fct_* models
│   └── observability/            # Audit timeline + idempotency views
├── macros/                       # SQL macros for cleaning and helpers
├── tests/                        # 4 singular SCD2 invariant tests
├── snapshots/                    # dbt snapshots
├── scripts/                      # PowerShell helpers
├── scheduler/                    # Local development dashboard
├── .github/                      # CI/CD workflows
└── docs/                         # Project documentation
```

## Getting Started

### Prerequisites
- Python 3.7+
- Databricks CLI (`pip install databricks-cli`)
- dbt Fusion CLI (`pip install dbt-core dbt-fusion`) (v2.0.0-preview.186+)
- Access to Databricks workspace with Unity Catalog

### Initial Setup

1. **Clone the repository**
   ```bash
   git clone <repo-url>
   cd sales_analytics
   ```

2. **Install dbt dependencies**
   ```bash
   pip install -r requirements.txt
   dbt deps --project-dir .
   ```

3. **Configure profiles.yml**
   - Set `DBT_TARGET=prod` or `dev` as needed
   - Set environment variables for Databricks credentials:
     ```bash
     export DATABRICKS_HOST="https://dbc-f49d67a0-6a22.cloud.databricks.com"
     export DATABRICKS_HTTP_PATH="/sql/1.0/warehouses/faced73bbff7e9f2"
     export DATABRICKS_TOKEN="your-token"
     ```

4. **Set up Unity Catalog**
   - Create `dbt` catalog (for dev) and `dbt_prod` catalog (for prod)
   - Ensure volume `/Volumes/dbt/raw/sales_analytics_raw` exists

## Common Workflows

### 1. Running the Pipeline

Build the entire project:
```bash
dbt build --profiles-dir .
```

Check build status:
```bash
dbt build --profiles-dir . --quiet
```

### 2. Running Models Locally

Run specific layers:

**Bronze layer (ingestion):
```bash
dbt run --profiles-dir . --select models/staging
```

**Silver layer (cleaning):
```bash
dbt run --profiles-dir . --select models/silver
```

**Gold layer (analytics):
```bash
dbt run --profiles-dir . --select models/gold
```

### 3. Running Tests

Run data quality tests:
```bash
dbt test --profiles-dir .
```

Check test results:
```bash
dbt test --profiles-dir . --output json --output-path target/test_results.json
```

### 4. Local Development with Scheduler

Start the local scheduler dashboard:
```bash
python scripts/run_scheduler.ps1
```

Access the dashboard at `http://localhost:5000`

### 5. Asset Bundle Deployment

Validate the bundle configuration:
```bash
.
```

Deploy to development:
```bash
# (This typically requires GitHub Actions, but you can run locally with extra setup)
```

Deploy to production:
```bash
# Similar to dev, but requires production catalog setup
```

## Macros and Helpers

### Available Macros

The project includes several SQL macros for common operations:

1. **`transform_helpers.sql`**: Cleaning and parsing helpers
2. **`incremental_helpers.sql`**: Late-arriving data windowing
3. **`logging.sql`**: Structured model/step/run logging
4. **`observability.sql`**: Audit table DDL and metrics
5. **`generate_schema_name.sql`**: Custom schema name handling

### How to Use Macros

Call macros from models:

```sql
{{ log_model_start() }}

-- Your model code here

{{ log_model_end() }}
```

## Data Quality

The project has deliberate data quality issues for practice:

### Issues in Raw Data (sales_analytics_raw/README.md)

**customers.csv issues:**
- City name variants and trailing spaces
- Country and email format inconsistencies
- Mixed date formats
- Duplicate rows
- Invalid email addresses

**products.csv issues:**
- Category case inconsistencies
- Negative unit prices
- Mixed date formats

### Quarantine Mechanism

Bad rows are sent to `quarantine_records` table instead of being silently dropped. Each row includes a `reject_reason` explaining why it was quarantined.

### Invariants

The gold layer includes SCD2 invariant tests to ensure customer dimension integrity.

## CI/CD

### GitHub Actions

1. **CI Workflow (dbt_ci.yml)**:
   - Runs on PR to main
   - Executes `dbt build` with quality gates
   - Fails if there are any errors (not warnings)

2. **Deploy Workflow (dbt_deploy.yml)**:
   - Runs on merge to main
   - Deploys Asset Bundles to gated prod
   - Requires approval for production deployment

### Local Development Mode

For local development, you can run:
```bash
dbt build --profiles-dir .
```

The CI/CD artifacts are stored in GitHub Actions for reference.

## Troubleshooting

### Common Issues

1. **Databricks Connection Issues**
   ```bash
   # Check your environment variables
   echo $DATABRICKS_HOST
   echo $DATABRICKS_HTTP_PATH
   echo $DATABRICKS_TOKEN
   ```

2. **Data Quality Failures**
   - Check the `quarantine_records` table in the silver layer
   - Review data quality docs in `docs/DATA_QUALITY.md`

3. **Macro Errors**
   - Ensure you're calling macros with the correct syntax
   - Check macro definitions in `macros/` directory

### Getting Help

1. Check the [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed design
2. Review [docs/DATA_QUALITY.md](docs/DATA_QUALITY.md) for expected issues
3. Look at the `scripts/` directory for local development helpers

## Next Steps

### For Developers

1. Explore the `models/` directory to understand the data model
2. Try running `dbt build` locally to see the pipeline in action
3. Check the `scheduler/` dashboard for run history and logs

### For Data Engineers

1. Add new tables to the gold layer as needed
2. Enhance data quality checks in the silver layer
3. Add new macros to the `macros/` directory

### For Business Users

1. Use the gold layer star schema for BI reporting
2. Check the `observability/` views for pipeline health
3. Review the data quality reports for data lineage

## Files and Directories

### Key Files

- `dbt_project.yml`: Project configuration
- `profiles.yml`: Environment profiles
- `databricks.yml`: Asset Bundle deployment config
- `README.md`: Project overview
- `SECURITY.md`: Security policies
- `CONTRIBUTING.md`: Contribution guidelines

### Important Directories

- `models/`: All dbt models (staging, silver, gold, observability)
- `macros/`: SQL macros for common operations
- `scheduler/`: Local development dashboard
- `scripts/`: PowerShell helpers for development
- `docs/`: Project documentation

## Version Control

### Branch Strategy

- **main**: Production-ready code
- **dev**: Development branch (currently merged with main)

### Commit Messages

Follow conventional commit format:
```
<type>(<scope>): <description>

<optional body>

<optional co-authored-by: openhands <openhands@all-hands.dev>>
```

Types include: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

## Support and Contact

For issues with this project:
1. Check existing issues in the repository
2. Review the documentation in the `docs/` directory
3. Check the CI/CD workflow logs in GitHub Actions
4. Contact the project maintainers for production support

---

*Last updated: $(date +'%Y-%m-%d')*
*Version: 1.0.0*