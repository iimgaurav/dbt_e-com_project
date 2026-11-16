-- =====================================================================
-- One-time Unity Catalog setup for the UAT and PROD environments.
-- Run this ONCE per workspace before the first build against a catalog
-- (see docs/PROD_CUTOVER.md). Idempotent: safe to re-run.
--
-- Execute in the Databricks SQL Editor with the SQL warehouse used by CI
-- (the same warehouse_id referenced in databricks.yml), as a user with
-- METASTORE ADMIN or MANAGE privileges on the metastore.
--
-- Replace <data-eng-group> with the principal (group or service principal)
-- that runs dbt in CI and the Databricks job, e.g. the app that owns
-- DATABRICKS_TOKEN in the GitHub environment secrets.
-- =====================================================================

-- ---------------------------------------------------------------------
-- UAT catalog
-- ---------------------------------------------------------------------
CREATE CATALOG IF NOT EXISTS dbt_uat
    COMMENT 'UAT catalog for the sales_analytics dbt project';

CREATE SCHEMA IF NOT EXISTS dbt_uat.bronze
    COMMENT 'Append-only raw landing (stg_* models)';
CREATE SCHEMA IF NOT EXISTS dbt_uat.silver
    COMMENT 'Cleaned, conformed slv_* models + quarantine_records';
CREATE SCHEMA IF NOT EXISTS dbt_uat.gold
    COMMENT 'Star-schema facts and dimensions for BI';
CREATE SCHEMA IF NOT EXISTS dbt_uat.observability
    COMMENT 'pipeline_step_log audit table + watermark_table';
CREATE SCHEMA IF NOT EXISTS dbt_uat.snapshots
    COMMENT 'dbt snapshot history (stores_snapshot)';

GRANT USE CATALOG ON CATALOG dbt_uat TO `<data-eng-group>`;
GRANT USE SCHEMA, CREATE TABLE, CREATE VIEW, MODIFY, SELECT
    ON SCHEMA dbt_uat.bronze        TO `<data-eng-group>`;
GRANT USE SCHEMA, CREATE TABLE, CREATE VIEW, MODIFY, SELECT
    ON SCHEMA dbt_uat.silver        TO `<data-eng-group>`;
GRANT USE SCHEMA, CREATE TABLE, CREATE VIEW, MODIFY, SELECT
    ON SCHEMA dbt_uat.gold          TO `<data-eng-group>`;
GRANT USE SCHEMA, CREATE TABLE, CREATE VIEW, MODIFY, SELECT
    ON SCHEMA dbt_uat.observability TO `<data-eng-group>`;
GRANT USE SCHEMA, CREATE TABLE, CREATE VIEW, MODIFY, SELECT
    ON SCHEMA dbt_uat.snapshots     TO `<data-eng-group>`;

-- ---------------------------------------------------------------------
-- PROD catalog
-- ---------------------------------------------------------------------
CREATE CATALOG IF NOT EXISTS dbt_prod
    COMMENT 'Production catalog for the sales_analytics dbt project';

CREATE SCHEMA IF NOT EXISTS dbt_prod.bronze
    COMMENT 'Append-only raw landing (stg_* models)';
CREATE SCHEMA IF NOT EXISTS dbt_prod.silver
    COMMENT 'Cleaned, conformed slv_* models + quarantine_records';
CREATE SCHEMA IF NOT EXISTS dbt_prod.gold
    COMMENT 'Star-schema facts and dimensions for BI';
CREATE SCHEMA IF NOT EXISTS dbt_prod.observability
    COMMENT 'pipeline_step_log audit table + watermark_table';
CREATE SCHEMA IF NOT EXISTS dbt_prod.snapshots
    COMMENT 'dbt snapshot history (stores_snapshot)';

GRANT USE CATALOG ON CATALOG dbt_prod TO `<data-eng-group>`;
GRANT USE SCHEMA, CREATE TABLE, CREATE VIEW, MODIFY, SELECT
    ON SCHEMA dbt_prod.bronze        TO `<data-eng-group>`;
GRANT USE SCHEMA, CREATE TABLE, CREATE VIEW, MODIFY, SELECT
    ON SCHEMA dbt_prod.silver        TO `<data-eng-group>`;
GRANT USE SCHEMA, CREATE TABLE, CREATE VIEW, MODIFY, SELECT
    ON SCHEMA dbt_prod.gold          TO `<data-eng-group>`;
GRANT USE SCHEMA, CREATE TABLE, CREATE VIEW, MODIFY, SELECT
    ON SCHEMA dbt_prod.observability TO `<data-eng-group>`;
GRANT USE SCHEMA, CREATE TABLE, CREATE VIEW, MODIFY, SELECT
    ON SCHEMA dbt_prod.snapshots     TO `<data-eng-group>`;

-- ---------------------------------------------------------------------
-- Read-only consumers (BI tools, analysts) get SELECT on gold only.
-- Uncomment and replace the principal when onboarding consumers.
-- ---------------------------------------------------------------------
-- GRANT USE CATALOG ON CATALOG dbt_prod TO `<bi-consumers>`;
-- GRANT USE SCHEMA, SELECT ON SCHEMA dbt_prod.gold TO `<bi-consumers>`;
