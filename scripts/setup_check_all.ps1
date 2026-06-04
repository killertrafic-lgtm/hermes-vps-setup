<#
.SYNOPSIS
    Запускает все диагностические проверки и сохраняет результат в logs/.

.DESCRIPTION
    Прогоняет:
      - check_environment.py
      - screenshot_desktop.py
      - list_windows.py
      - chrome_debug_check.py

    Результат складывает в logs/setup_check_YYYYMMDD_HHMMSS.txt
#>

$ErrorActionPreference = "Continue"
$ProjectRoot = "C:\product-research-agent"
$Scripts = Join-Path $ProjectRoot "scripts"
$Logs = Join-Path $ProjectRoot "logs"
$Venv = Join-Path $ProjectRoot ".venv"
$Python = Join-Path $Venv "Scripts\python.exe"

if (-not (Test-Path $Python)) {
    Write-Host "[ERROR] Python venv not found at $Venv" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $Logs -Force | Out-Null

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Report = Join-Path $Logs "setup_check_$Timestamp.txt"

$ScriptList = @(
    "check_environment.py",
    "screenshot_desktop.py",
    "list_windows.py",
    "chrome_debug_check.py"
)

"=== Hermes VPS Setup Check === $Timestamp ===`n" | Set-Content $Report

foreach ($s in $ScriptList) {
    $path = Join-Path $Scripts $s
    if (-not (Test-Path $path)) {
        "[SKIP] $s not found" | Add-Content $Report
        Write-Host "[SKIP] $s not found" -ForegroundColor Yellow
        continue
    }
    Write-Host "[RUN] $s" -ForegroundColor Cyan
    "`n--- $s ---" | Add-Content $Report
    try {
        $out = & $Python $path 2>&1
        $out | Add-Content $Report
        Write-Host "[OK] $s done" -ForegroundColor Green
    } catch {
        "[ERROR] $_" | Add-Content $Report
        Write-Host "[ERROR] $s : $_" -ForegroundColor Red
    }
}

"`n=== END === $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Add-Content $Report

Write-Host "`n[DONE] Report saved to: $Report" -ForegroundColor Green
Write-Host "Show last 50 lines:"
Get-Content $Report | Select-Object -Last 50
