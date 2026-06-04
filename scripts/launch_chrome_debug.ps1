<#
.SYNOPSIS
    Запускает Google Chrome с remote debugging port 9222.

.DESCRIPTION
    Hermes Agent сможет подключиться к http://127.0.0.1:9222/json/version
    и управлять Chrome через Chrome DevTools Protocol (CDP).

    Использует отдельный user-data-dir чтобы не конфликтовать с обычным
    профилем Chrome пользователя.

.PARAMETER Port
    Remote debugging port. По умолчанию 9222.

.PARAMETER ProfileDir
    Папка для user-data-dir. По умолчанию C:\product-research-agent\chrome-debug-profile.

.PARAMETER StartUrl
    Стартовая страница. По умолчанию about:blank.

.EXAMPLE
    .\launch_chrome_debug.ps1
    .\launch_chrome_debug.ps1 -StartUrl "https://adheart.me/ru/ads"
#>

param(
    [int]$Port = 9222,
    [string]$ProfileDir = "C:\product-research-agent\chrome-debug-profile",
    [string]$StartUrl = "about:blank"
)

$ErrorActionPreference = "Stop"

# Найти chrome.exe
$chromeCandidates = @(
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)

$chrome = $chromeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $chrome) {
    Write-Host "[ERROR] Chrome not found in standard paths:" -ForegroundColor Red
    $chromeCandidates | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host "[OK] Chrome found: $chrome" -ForegroundColor Green

# Создать профиль если нет
if (-not (Test-Path $ProfileDir)) {
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
    Write-Host "[OK] Created profile dir: $ProfileDir"
}

# Проверить - не запущен ли уже
$existing = Get-Process chrome -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*remote-debugging-port=$Port*" }

if ($existing) {
    Write-Host "[WARN] Chrome with --remote-debugging-port=$Port already running (PID $($existing.Id))" -ForegroundColor Yellow
    Write-Host "Kill existing? (y/N): " -NoNewline
    $r = Read-Host
    if ($r -eq "y") {
        $existing | Stop-Process -Force
        Start-Sleep -Seconds 2
    } else {
        Write-Host "Aborted."
        exit 0
    }
}

# Аргументы запуска
$arguments = @(
    "--remote-debugging-port=$Port",
    "--remote-debugging-address=127.0.0.1",  # только localhost - безопасность
    "--user-data-dir=$ProfileDir",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-features=Translate",
    $StartUrl
)

Write-Host "Launching Chrome with:" -ForegroundColor Cyan
$arguments | ForEach-Object { Write-Host "  $_" }

$process = Start-Process -FilePath $chrome -ArgumentList $arguments -PassThru

Write-Host "[OK] Chrome launched. PID: $($process.Id)" -ForegroundColor Green
Write-Host "Remote debugging: http://127.0.0.1:$Port/json/version"
Write-Host "Profile: $ProfileDir"

# Подождать 3 сек и проверить что endpoint отвечает
Start-Sleep -Seconds 3
try {
    $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 5
    Write-Host "[OK] Debug endpoint reachable. Browser: $($resp.Browser)" -ForegroundColor Green
} catch {
    Write-Host "[WARN] Debug endpoint not yet reachable: $_" -ForegroundColor Yellow
    Write-Host "Wait a few seconds and run scripts\chrome_debug_check.py"
}
