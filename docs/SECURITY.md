# Security

## 1. Secrets model

The project **does not store credentials in version control**.

| Secret | How it is supplied | Where it is used |
|---|---|---|
| `DATABRICKS_TOKEN` | Environment variable | `profiles.yml` (`{{ env_var('DATABRICKS_TOKEN') }}`) |
| `DATABRICKS_HOST` | Environment variable (has a default) | `profiles.yml` |
| `DATABRICKS_HTTP_PATH` | Environment variable (has a default) | `profiles.yml` |
| CI credentials | GitHub Actions repository secrets | `.github/workflows/dbt_ci.yml` |
| Job credentials | Databricks job identity (no PAT in the bundle) | `resources/dbt_job.yml` |

`profiles.yml` is committed on purpose: it contains only host/warehouse
defaults and `env_var()` references, never a token.

`dbt_project.yml` contains no secrets. `.gitignore` excludes `.env`,
`profiles.local.yml`, `target/`, `logs/` and `dbt_packages/`.

## 2. ⚠️ Outstanding remediation — plaintext PAT on disk

A credential audit found a **personal access token stored in plaintext** in
local files. One of them was inside the repository working tree:

| File | Field | Status |
|---|---|---|
| `C:\temp\DBT_project\sales_analytics\.vscode\settings.json` | `dbt.environmentVariables.DATABRICKS_TOKEN` | **Removed before the first commit**; `.vscode/` is now gitignored |
| `C:\temp\DBT_project\.vscode\settings.json` | `dbt.environmentVariables.DATABRICKS_TOKEN` | **Needs removal** (outside the repo) |
| `C:\temp\DBT_project\.env` | `DATABRICKS_TOKEN` | **Needs removal / rotate** (outside the repo) |

The in-repo copy never entered git history: the token was stripped and
`.vscode/` added to `.gitignore` before `git init`/`git add`. The two files
outside the repository are not committed, but they are on disk in plaintext and
the token has been exposed in this working session.

### Required actions (in order)

1. **Rotate the token now.** In the Databricks UI:
   **User Settings → Developer → Access tokens → Revoke**, then create a new
   token.
2. **Remove the value from `settings.json`.** Keep the other VS Code settings:

   ```json
   {
     "files.associations": { "*.sql": "jinja-sql" },
     "dbt.dbtPythonPath": "C:\\Python314\\python.exe",
     "dbt.dbtPath": "C:\\Users\\Navneet\\.local\\bin\\dbt.exe"
   }
   ```

   If VS Code needs the token, load it from the user environment instead of the
   workspace file.
3. **Delete or empty `.env`**, or replace it with the non-secret template
   `.env.example`.
4. **Put the new token in the OS keychain / user environment**, not a file:

   ```powershell
   [Environment]::SetEnvironmentVariable("DATABRICKS_TOKEN", "<new-token>", "User")
   ```

   Then restart the shell and VS Code.
5. **Update the GitHub secret** `DATABRICKS_TOKEN` with the new value.
6. **Confirm the old token is dead**: `databricks auth describe` should fail
   with the old value and succeed with the new one.

> Until step 1 is done, treat the token as compromised.

## 3. Token rotation

### Personal token

```powershell
# 1. Revoke in the UI (User Settings → Developer → Access tokens)
# 2. Create a replacement
# 3. Store it outside the repo
[Environment]::SetEnvironmentVariable("DATABRICKS_TOKEN", "<new-token>", "User")
# 4. Update CI
gh secret set DATABRICKS_TOKEN --body "<new-token>"
```

### Service principal (recommended for production)

1. Create a service principal in the account console.
2. Grant it `USE CATALOG`, `USE SCHEMA`, `SELECT`, `MODIFY`, `CREATE TABLE` on
   `dbt_prod`, and `READ VOLUME` on the raw volume.
3. Create a token for the service principal and store it as the CI secret.
4. Rotate on a fixed schedule (e.g. every 90 days) and record the rotation date.

## 4. Least privilege

Recommended grants for the production identity:

```sql
GRANT USE CATALOG ON CATALOG dbt_prod TO `<principal>`;
GRANT USE SCHEMA  ON SCHEMA  dbt_prod.bronze TO `<principal>`;
GRANT USE SCHEMA  ON SCHEMA  dbt_prod.silver TO `<principal>`;
GRANT USE SCHEMA  ON SCHEMA  dbt_prod.gold   TO `<principal>`;

GRANT CREATE TABLE, MODIFY, SELECT ON SCHEMA dbt_prod.bronze TO `<principal>`;
GRANT CREATE TABLE, MODIFY, SELECT ON SCHEMA dbt_prod.silver TO `<principal>`;
GRANT CREATE TABLE, MODIFY, SELECT ON SCHEMA dbt_prod.gold   TO `<principal>`;

GRANT READ VOLUME ON VOLUME dbt_prod.raw.sales_analytics_raw TO `<principal>`;
```

BI consumers should get **`SELECT` on `gold` only**, not on `bronze`/`silver`
and never `MODIFY`.

```sql
GRANT USE CATALOG ON CATALOG dbt_prod TO `bi-consumers`;
GRANT USE SCHEMA  ON SCHEMA  dbt_prod.gold TO `bi-consumers`;
GRANT SELECT      ON SCHEMA  dbt_prod.gold TO `bi-consumers`;
```

Avoid granting `ALL PRIVILEGES` or catalog-wide `MODIFY`.

## 5. PII and data classification

| Column | Classification | Notes |
|---|---|---|
| `first_name`, `last_name`, `full_name` | PII | Present in `slv_customers`, `dim_customers*` |
| `email` | PII (contact) | Lower-cased but not masked |
| `phone` | PII (contact) | Not masked |
| `city`, `state`, `country` | Quasi-identifier | Low sensitivity individually |
| `transaction_ref` | Financial reference | Not a card number; still sensitive |
| Amounts, dates, statuses | Non-PII | Safe for broad analytics |

**No masking is currently implemented.** Before exposing gold to a wide
audience:

- [ ] Apply Unity Catalog **column masks** on `email` and `phone`
- [ ] Apply **row filters** if regional access restrictions apply
- [ ] Restrict `dim_customers*` to roles that need customer-level detail
- [ ] Publish an aggregated `dim_customers_masked` for general BI use
- [ ] Tag columns with Unity Catalog tags (`pii`, `contact`) for discovery

Example column mask (requires a masking function):

```sql
ALTER TABLE dbt_prod.gold.dim_customers
ALTER COLUMN email SET MASK dbt_prod.security.mask_email;
```

## 6. Data integrity controls

- Raw files are read-only inputs; the pipeline never writes back to the volume.
- All writes go through dbt into `<catalog>.{bronze,silver,gold}`.
- `dbt build` runs tests **before** downstream models consume a parent, so a
  failing structural test stops propagation.
- SCD2 history is append-only; no process issues `DELETE` or `UPDATE` against it
  outside dbt's merge.
- Delta time travel is available for recovery (`VERSION AS OF`, `RESTORE`).

## 7. Logging and audit

| Source | What is captured |
|---|---|
| `logs/dbt.log` | Every node, SQL, timing, warnings/errors |
| `target/run_results.json` | Per-node status and timing |
| Databricks job UI | Run history, task output, retries |
| Unity Catalog audit logs | Table/volume access (workspace-level setting) |
| GitHub Actions | CI runs and uploaded artifacts (14 days) |

No secrets are written to logs. Rendered SQL may contain data values, so treat
`target/` and `logs/` as internal artifacts and do not publish them.

## 8. Security checklist

- [ ] No plaintext token in any tracked or untracked file (see §2)
- [ ] `.env` absent or reduced to the non-secret template
- [ ] Token rotated after any exposure
- [ ] CI uses a service principal, not a personal PAT
- [ ] Prod grants follow least privilege (§4)
- [ ] BI access limited to `gold`
- [ ] PII masking decision recorded (§5)
- [ ] `.gitignore` covers `target/`, `logs/`, `.env*`, `profiles.local.yml`
- [ ] No secrets in `databricks.yml`, `resources/`, or `profiles.yml`
- [ ] Access tokens have an expiry (≤ 90 days)
