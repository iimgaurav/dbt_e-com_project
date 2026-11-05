# Deploy the Databricks Asset Bundle (job definition) for a target.
param(
    [string]$Target = "prod"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot

Push-Location $projectRoot
try {
    databricks bundle validate -t $Target --profile DEFAULT
    if ($LASTEXITCODE -ne 0) { throw "bundle validate failed" }

    databricks bundle deploy -t $Target --profile DEFAULT
    if ($LASTEXITCODE -ne 0) { throw "bundle deploy failed" }
}
finally {
    Pop-Location
}
