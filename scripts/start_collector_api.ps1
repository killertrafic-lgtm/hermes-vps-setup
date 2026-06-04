<#
.SYNOPSIS
    Запускает Hermes Collector API локально (127.0.0.1:8765 по умолчанию).

.DESCRIPTION
    Активирует venv и запускает collector_api.py. По умолчанию слушает
    только localhost. Для внешнего доступа - задать HERMES_COLLECTOR_TOKEN
    и COLLECTOR_HOST=0.0.0.0 в config/.env.

.PARAMETER Background
    Запустить в фоне как отдельный процесс (PID файл logs/collector_api.pid).
#>

param(
    [switch]$Background
)

$ErrorActionPreference = "Stop"
$ProjectRoot = "C:\product-research-agent"
$Venv = Join-Path $ProjectRoot ".venv"
$Python = Join-Path $Venv "Scripts\python.exe"
$Api = Join-Path $ProjectRoot "scripts\collector_api.py"
$Logs = Join-Path $ProjectRoot "logs"

if (-not (Test-Path $Python)) {
    Write-Host "[ERROR] Python venv not found at $Venv" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $Api)) {
    Write-Host "[ERROR] collector_api.py not found at $Api" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $Logs -Force | Out-Null

if ($Background) {
    $pidFile = Join-Path $Logs "collector_api.pid"
    $logFile = Join-Path $Logs "collector_api.log"
    $process = Start-Process -FilePath $Python -ArgumentList $Api `
        -WorkingDirectory $ProjectRoot `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError (Join-Path $Logs "collector_api.err.log") `
        -PassThru -WindowStyle Hidden
    $process.Id | Set-Content $pidFile
    Write-Host "[OK] Collector API started in background. PID: $($process.Id)" -ForegroundColor Green
    Write-Host "Log: $logFile"
    Write-Host "PID file: $pidFile"
    Write-Host "Health: curl http://127.0.0.1:8765/health"
} else {
    Write-Host "[INFO] Starting Collector API in foreground (Ctrl+C to stop)" -ForegroundColor Cyan
    & $Python $Api
}
