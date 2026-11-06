# Start the local dbt scheduler dashboard.
#
#   .\scripts\run_scheduler.ps1                 # create venv if needed, run on 5055
#   .\scripts\run_scheduler.ps1 -Port 5060      # different port
#   .\scripts\run_scheduler.ps1 -Install        # install/update dependencies only
#   .\scripts\run_scheduler.ps1 -NoBrowser      # do not open the browser
#
# The dashboard binds to 127.0.0.1 and must stay running to fire the schedule.
param(
    [int]$Port = 5055,
    [switch]$Install,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$schedulerDir = Join-Path $projectRoot "scheduler"
$venvDir = Join-Path $schedulerDir ".venv"
$python = Join-Path $venvDir "Scripts\python.exe"
$requirements = Join-Path $schedulerDir "requirements.txt"

function New-SchedulerVenv {
    Write-Host "Creating virtual environment in $venvDir ..."
    & python -m venv $venvDir
    if ($LASTEXITCODE -ne 0) { throw "Could not create the virtual environment." }
    & $python -m pip install --upgrade pip
    if ($LASTEXITCODE -ne 0) { throw "Could not upgrade pip." }
}

function Install-SchedulerDependencies {
    Write-Host "Installing scheduler dependencies ..."
    & $python -m pip install -r $requirements
    if ($LASTEXITCODE -ne 0) { throw "Could not install scheduler dependencies." }
}

if (-not (Test-Path $python)) {
    New-SchedulerVenv
    Install-SchedulerDependencies
}
elseif ($Install) {
    Install-SchedulerDependencies
}

if ($Install) {
    Write-Host "Scheduler dependencies are up to date."
    exit 0
}

$env:SCHEDULER_PORT = "$Port"
$appArgs = @((Join-Path $schedulerDir "app.py"))
if ($NoBrowser) { $appArgs += "--no-browser" }

Write-Host "Starting sales_analytics scheduler on http://127.0.0.1:$Port"
Write-Host "Press Ctrl+C to stop. The daily build only fires while this app is running."
& $python @appArgs
