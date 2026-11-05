# Build the project against the dev target.
# Token is read from the Databricks CLI profile so nothing is hardcoded.
param(
    [string]$Target = "dev",
    [string]$Select = "",
    [switch]$FullRefresh
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot

$token = (Select-String -Path "$env:USERPROFILE\.databrickscfg" -Pattern '^token\s*=\s*(.+)$').Matches[0].Groups[1].Value.Trim()
$env:DATABRICKS_TOKEN = $token
$env:DBT_TARGET = $Target

$dbtArgs = @("build", "--profiles-dir", ".")
if ($Select) { $dbtArgs += @("--select", $Select) }
if ($FullRefresh) { $dbtArgs += "--full-refresh" }

Push-Location $projectRoot
try {
    & dbt @dbtArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
