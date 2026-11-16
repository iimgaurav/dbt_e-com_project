<#
.SYNOPSIS
    Production cutover for the sales_analytics dbt project.

.DESCRIPTION
    End-to-end promotion path that mirrors the CI pipeline but runs on a
    local machine with the Databricks CLI authenticated:

        1. Preflight:   verify DATABRICKS_HOST / DATABRICKS_TOKEN are set.
        2. UAT build:   dbt build against dbt_uat (catalog from databricks.yml).
        3. PROD build:  dbt build against dbt_prod.
        4. Bundle:      databricks bundle deploy -t prod (deploys the paused job).
        5. Verify run:  databricks bundle run sales_analytics_dbt -t prod.
        6. -Unpause:    flip pause_status to UNPAUSED in resources/dbt_job.yml,
                        redeploy the bundle so the schedule goes live.

    Run resources/prod_catalog_setup.sql once per workspace BEFORE the first
    build (see docs/PROD_CUTOVER.md).

.PARAMETER FullRefresh
    Rebuild incremental models from scratch in UAT and PROD.

.PARAMETER SkipProdBuild
    Stop after the UAT build (useful to validate changes without touching prod).

.PARAMETER Unpause
    Unpause the scheduled Databricks job (assumes the manual run succeeded).

.EXAMPLE
    .\scripts\prod_cutover.ps1                        # full cutover
    .\scripts\prod_cutover.ps1 -FullRefresh           # rebuild incrementals
    .\scripts\prod_cutover.ps1 -SkipProdBuild         # UAT only
    .\scripts\prod_cutover.ps1 -Unpause               # go live after a good run
#>
[CmdletBinding()]
param(
    [switch]$FullRefresh,
    [switch]$SkipProdBuild,
    [switch]$Unpause
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) {
        Write-Host "::error::$Name failed (exit $LASTEXITCODE)." -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

# ---------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------
Invoke-Step 'Preflight' {
    foreach ($var in 'DATABRICKS_HOST', 'DATABRICKS_TOKEN') {
        if (-not [Environment]::GetEnvironmentVariable($var)) {
            throw "$var is not set. Export it before running the cutover."
        }
    }
    foreach ($tool in 'dbt', 'databricks') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool CLI not found on PATH."
        }
    }
    Write-Host "DATABRICKS_HOST / DATABRICKS_TOKEN set; dbt and databricks CLIs found."
}

# ---------------------------------------------------------------------
# 1. UAT build (dbt target uat -> catalog dbt_uat)
# ---------------------------------------------------------------------
Invoke-Step 'UAT build' {
    $args = @('build', '--profiles-dir', '.', '--target', 'uat')
    if ($FullRefresh) { $args += '--full-refresh' }
    Write-Host "dbt $($args -join ' ')"
    dbt @args
}

if ($SkipProdBuild) {
    Write-Host ""
    Write-Host 'Skipping prod as requested (-SkipProdBuild).' -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------
# 2. PROD build (dbt target prod -> catalog dbt_prod)
# ---------------------------------------------------------------------
Invoke-Step 'PROD build' {
    $args = @('build', '--profiles-dir', '.', '--target', 'prod')
    if ($FullRefresh) { $args += '--full-refresh' }
    Write-Host "dbt $($args -join ' ')"
    dbt @args
}

# ---------------------------------------------------------------------
# 3. Deploy the Databricks bundle (job stays paused on first deploy)
# ---------------------------------------------------------------------
Invoke-Step 'Bundle deploy (prod target)' {
    databricks bundle deploy -t prod
}

# ---------------------------------------------------------------------
# 4. Manual verification run of the deployed job
# ---------------------------------------------------------------------
Invoke-Step 'Bundle run (manual verification)' {
    databricks bundle run sales_analytics_dbt -t prod
}

# ---------------------------------------------------------------------
# 5. Optional: unpause the schedule
# ---------------------------------------------------------------------
if ($Unpause) {
    Invoke-Step 'Unpause scheduled job' {
        $jobFile = Join-Path $ProjectRoot 'resources\dbt_job.yml'
        $content = Get-Content $jobFile -Raw
        $updated = $content -replace 'pause_status:\s*PAUSED.*', 'pause_status: UNPAUSED # scheduled by scripts/prod_cutover.ps1 -Unpause'
        if ($updated -eq $content) {
            throw "No 'pause_status: PAUSED' found in resources/dbt_job.yml - is it already unpaused?"
        }
        Set-Content $jobFile $updated -NoNewline
        Write-Host 'resources/dbt_job.yml flipped to UNPAUSED; redeploying bundle...'
        databricks bundle deploy -t prod
    }
    Write-Host ""
    Write-Host 'Job is live on its 02:30 Asia/Kolkata schedule.' -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host 'Job deployed PAUSED. After you have verified the manual run, go live with:' -ForegroundColor Yellow
    Write-Host '    .\scripts\prod_cutover.ps1 -Unpause' -ForegroundColor Yellow
}
