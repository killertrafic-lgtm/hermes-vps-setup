<#
.SYNOPSIS
    Hermes VPS Setup - главный скрипт инициализации.

.DESCRIPTION
    Подготавливает Windows VPS для управления через Hermes Agent:
      1. Создаёт структуру папок C:\product-research-agent\{scripts,runs,...}
      2. Копирует все диагностические скрипты в C:\product-research-agent\scripts\
      3. Активирует существующий Python venv и доставляет недостающие pip пакеты
      4. Устанавливает + конфигурирует OpenSSH Server
      5. Создаёт пользователя hermes_worker (запрашивает пароль интерактивно)
      6. Опционально настраивает SSH key auth (запрашивает ключ интерактивно)
      7. Запускает диагностические проверки
      8. Генерирует ACCESS_FOR_HERMES.md с актуальными данными VPS

    Безопасность:
      - Пароли НЕ записываются в файлы
      - Firewall не отключается, добавляется только правило для порта 22
      - Collector API по умолчанию слушает только 127.0.0.1
      - WhiteTools НЕ трогается

.PARAMETER ProjectRoot
    Корень проекта. По умолчанию C:\product-research-agent.

.PARAMETER SkipUserCreation
    Не создавать hermes_worker (если уже создан / используется другой).

.PARAMETER SkipSSH
    Не устанавливать OpenSSH Server (если уже установлен / не нужен).

.PARAMETER NonInteractive
    Не задавать вопросы - для CI. Эквивалентно SkipUserCreation + SkipSSH-key.

.EXAMPLE
    # Стандартный запуск (от Administrator):
    .\bootstrap.ps1

    # Только диагностика без создания пользователя и SSH:
    .\bootstrap.ps1 -SkipUserCreation -SkipSSH
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = "C:\product-research-agent",
    [switch]$SkipUserCreation,
    [switch]$SkipSSH,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"
$global:ProgressPreference = "SilentlyContinue"  # ускоряет Invoke-WebRequest

# =============================================================================
# 0. Header + Admin check
# =============================================================================
Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " Hermes VPS Setup - Bootstrap                  " -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] "Administrator")

if (-not $isAdmin) {
    Write-Host "[ERROR] Run this script as Administrator." -ForegroundColor Red
    Write-Host "  Right-click PowerShell -> Run as Administrator, then re-run."
    exit 1
}

Write-Host "[OK] Running as Administrator" -ForegroundColor Green

# Где лежит этот скрипт + другие файлы репо
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "Source dir: $ScriptDir"
Write-Host "Project root: $ProjectRoot"
Write-Host ""

# =============================================================================
# 1. Создать структуру папок
# =============================================================================
Write-Host "[1/9] Creating folder structure..." -ForegroundColor Cyan
$subdirs = @("scripts", "runs", "logs", "screenshots", "exports", "config", "docs")
foreach ($s in $subdirs) {
    $path = Join-Path $ProjectRoot $s
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Write-Host "  Created: $path"
    }
}
Write-Host "[OK] Folder structure ready" -ForegroundColor Green
Write-Host ""

# =============================================================================
# 2. Скопировать скрипты из repo в ProjectRoot
# =============================================================================
Write-Host "[2/9] Copying scripts from repo..." -ForegroundColor Cyan
$sourceFolders = @(
    @{ From = "scripts"; To = "scripts" },
    @{ From = "config";  To = "config" }
)
foreach ($pair in $sourceFolders) {
    $src = Join-Path $ScriptDir $pair.From
    $dst = Join-Path $ProjectRoot $pair.To
    if (Test-Path $src) {
        Copy-Item -Path "$src\*" -Destination $dst -Recurse -Force
        $count = (Get-ChildItem $src -File -Recurse).Count
        Write-Host "  Copied $count files: $src -> $dst"
    } else {
        Write-Host "  [WARN] Source not found: $src" -ForegroundColor Yellow
    }
}

# requirements.txt
$req = Join-Path $ScriptDir "requirements.txt"
if (Test-Path $req) {
    Copy-Item $req (Join-Path $ProjectRoot "requirements.txt") -Force
}
Write-Host "[OK] Scripts copied" -ForegroundColor Green
Write-Host ""

# =============================================================================
# 3. Python venv + установка пакетов
# =============================================================================
Write-Host "[3/9] Setting up Python venv..." -ForegroundColor Cyan
$venvPath = Join-Path $ProjectRoot ".venv"
$pythonExe = Join-Path $venvPath "Scripts\python.exe"

# Если venv нет - создать
if (-not (Test-Path $pythonExe)) {
    Write-Host "  venv not found, creating..."
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
    & python -m venv $venvPath
    if (-not (Test-Path $pythonExe)) {
        Write-Host "[ERROR] Failed to create venv. Is Python installed?" -ForegroundColor Red
        exit 1
    }
}

Write-Host "  Using: $pythonExe"
& $pythonExe -m pip install --upgrade pip --quiet
Write-Host "  Installing/updating packages from requirements.txt..."
$reqFile = Join-Path $ProjectRoot "requirements.txt"
if (Test-Path $reqFile) {
    & $pythonExe -m pip install -r $reqFile --quiet 2>&1 | Out-Host
} else {
    Write-Host "  [WARN] requirements.txt not found, installing core packages manually"
    & $pythonExe -m pip install --quiet `
        playwright requests pandas pillow pyautogui pytesseract `
        opencv-python beautifulsoup4 lxml python-dotenv `
        fastapi "uvicorn[standard]" psutil pywinauto pywin32 mss aiohttp
}

# Playwright Chromium (если ещё нет)
$playwrightDir = "$env:LOCALAPPDATA\ms-playwright"
if (-not (Test-Path $playwrightDir)) {
    Write-Host "  Installing Playwright Chromium..."
    & $pythonExe -m playwright install chromium 2>&1 | Out-Host
}
Write-Host "[OK] Python environment ready" -ForegroundColor Green
Write-Host ""

# =============================================================================
# 4. OpenSSH Server
# =============================================================================
if (-not $SkipSSH) {
    Write-Host "[4/9] Installing OpenSSH Server..." -ForegroundColor Cyan
    $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $sshd) {
        Write-Host "  Installing OpenSSH.Server capability..."
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    } else {
        Write-Host "  sshd already installed"
    }

    # Start + autostart
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd -ErrorAction SilentlyContinue
    $sshd = Get-Service sshd
    Write-Host "  sshd status: $($sshd.Status), startup: $((Get-Service sshd).StartType)"

    # Firewall rule
    $rule = Get-NetFirewallRule -Name "sshd" -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -Name sshd -DisplayName "OpenSSH Server (sshd)" `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
            -LocalPort 22 -Profile Any | Out-Null
        Write-Host "  Firewall rule for TCP 22 added"
    } else {
        Write-Host "  Firewall rule for TCP 22 already exists"
    }

    # Default shell - PowerShell (удобнее чем cmd для скриптов)
    $shellKey = "HKLM:\SOFTWARE\OpenSSH"
    if (-not (Test-Path $shellKey)) {
        New-Item -Path $shellKey -Force | Out-Null
    }
    $psPath = (Get-Command powershell).Source
    New-ItemProperty -Path $shellKey -Name DefaultShell -Value $psPath `
        -PropertyType String -Force | Out-Null
    Write-Host "  Default SSH shell: PowerShell"

    Write-Host "[OK] OpenSSH Server configured" -ForegroundColor Green
} else {
    Write-Host "[4/9] Skipping OpenSSH (--SkipSSH)" -ForegroundColor Yellow
}
Write-Host ""

# =============================================================================
# 5. Создать пользователя hermes_worker
# =============================================================================
$hermesUser = "hermes_worker"
$userCreated = $false
if (-not $SkipUserCreation -and -not $NonInteractive) {
    Write-Host "[5/9] Creating user '$hermesUser'..." -ForegroundColor Cyan

    $existing = Get-LocalUser -Name $hermesUser -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  User '$hermesUser' already exists" -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "  >>> Enter password for $hermesUser (min 8 chars, mixed case + digit)"
        Write-Host "  >>> Password is NOT stored anywhere except Windows SAM"
        $pwd = Read-Host -AsSecureString "  Password"
        $pwdConfirm = Read-Host -AsSecureString "  Confirm password"

        # Сверить
        $pwdPlain = [System.Net.NetworkCredential]::new("", $pwd).Password
        $pwdConfirmPlain = [System.Net.NetworkCredential]::new("", $pwdConfirm).Password
        if ($pwdPlain -ne $pwdConfirmPlain) {
            Write-Host "[ERROR] Passwords don't match. Skipping user creation." -ForegroundColor Red
        } else {
            try {
                New-LocalUser -Name $hermesUser -Password $pwd `
                    -PasswordNeverExpires -AccountNeverExpires `
                    -Description "Hermes Agent worker" | Out-Null
                Write-Host "  [OK] User '$hermesUser' created" -ForegroundColor Green
                $userCreated = $true

                # Спросить - добавлять ли в Administrators
                Write-Host ""
                Write-Host "  Add '$hermesUser' to Administrators group? (admin needed for full automation)"
                $addAdmin = Read-Host "  Add to Administrators? [y/N]"
                if ($addAdmin -eq "y") {
                    Add-LocalGroupMember -Group "Administrators" -Member $hermesUser
                    Write-Host "  [OK] Added to Administrators" -ForegroundColor Green
                } else {
                    # Дать как минимум права на проектную папку
                    Write-Host "  Granting full control on $ProjectRoot to $hermesUser..."
                    icacls $ProjectRoot /grant "${hermesUser}:F" /T /Q | Out-Null
                    Write-Host "  [OK] User can read/write project folder"
                }
            } catch {
                Write-Host "[ERROR] Failed to create user: $_" -ForegroundColor Red
            }
        }
        # Очистить переменные
        $pwdPlain = $null; $pwdConfirmPlain = $null
        [System.GC]::Collect()
    }
} else {
    Write-Host "[5/9] Skipping user creation" -ForegroundColor Yellow
}
Write-Host ""

# =============================================================================
# 6. SSH key auth (опционально)
# =============================================================================
$sshKeyAdded = $false
if (-not $SkipSSH -and -not $NonInteractive) {
    Write-Host "[6/9] SSH key authentication setup..." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Do you have an SSH PUBLIC key from Hermes Agent to add?"
    Write-Host "  (typically: ssh-ed25519 AAAA... user@host)"
    $addKey = Read-Host "  Add SSH key now? [y/N]"

    if ($addKey -eq "y") {
        Write-Host "  Paste public key (single line, ENTER to confirm):"
        $pubKey = Read-Host
        $pubKey = $pubKey.Trim()

        if ($pubKey -match "^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-)") {
            $targetUser = if ($userCreated) { $hermesUser } else { "Administrator" }

            $isAdminUser = (Get-LocalGroupMember -Group "Administrators" |
                Where-Object { $_.Name -like "*\$targetUser" }) -ne $null

            if ($isAdminUser) {
                $keysFile = "C:\ProgramData\ssh\administrators_authorized_keys"
                $keysDir = Split-Path $keysFile -Parent
            } else {
                $keysDir = "C:\Users\$targetUser\.ssh"
                $keysFile = Join-Path $keysDir "authorized_keys"
            }

            if (-not (Test-Path $keysDir)) {
                New-Item -ItemType Directory -Path $keysDir -Force | Out-Null
            }
            Add-Content -Path $keysFile -Value $pubKey -Encoding ASCII

            # ACL - критически важно для OpenSSH on Windows
            icacls $keysFile /inheritance:r | Out-Null
            if ($isAdminUser) {
                icacls $keysFile /grant "Administrators:F" "SYSTEM:F" | Out-Null
                icacls $keysDir /inheritance:r | Out-Null
                icacls $keysDir /grant "Administrators:F" "SYSTEM:F" | Out-Null
            } else {
                icacls $keysFile /grant "${targetUser}:F" "SYSTEM:F" | Out-Null
                icacls $keysDir /inheritance:r | Out-Null
                icacls $keysDir /grant "${targetUser}:F" "SYSTEM:F" | Out-Null
            }
            Write-Host "  [OK] Key added to $keysFile" -ForegroundColor Green
            $sshKeyAdded = $true
        } else {
            Write-Host "  [WARN] Invalid key format, skipping" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Skipped. Password auth remains enabled."
    }
} else {
    Write-Host "[6/9] Skipping SSH key setup" -ForegroundColor Yellow
}
Write-Host ""

# =============================================================================
# 7. Config файлы
# =============================================================================
Write-Host "[7/9] Creating config files..." -ForegroundColor Cyan
$envFile = Join-Path $ProjectRoot "config\.env"
$envExample = Join-Path $ProjectRoot "config\.env.example"
if (-not (Test-Path $envFile) -and (Test-Path $envExample)) {
    Copy-Item $envExample $envFile
    Write-Host "  Created: $envFile (copy from .env.example)"
}
Write-Host "[OK] Config files ready" -ForegroundColor Green
Write-Host ""

# =============================================================================
# 8. Запустить диагностику
# =============================================================================
Write-Host "[8/9] Running diagnostic checks..." -ForegroundColor Cyan
$setupCheckAll = Join-Path $ProjectRoot "scripts\setup_check_all.ps1"
if (Test-Path $setupCheckAll) {
    try {
        & $setupCheckAll
    } catch {
        Write-Host "  [WARN] Diagnostic run failed: $_" -ForegroundColor Yellow
    }
}
Write-Host ""

# =============================================================================
# 9. Сгенерировать ACCESS_FOR_HERMES.md
# =============================================================================
Write-Host "[9/9] Generating ACCESS_FOR_HERMES.md..." -ForegroundColor Cyan

function Get-PublicIP {
    try {
        return (Invoke-RestMethod -Uri "https://api.ipify.org?format=json" -TimeoutSec 5).ip
    } catch {
        return "unable to fetch"
    }
}

function Find-ExecutablePath {
    param([string[]]$Candidates)
    foreach ($p in $Candidates) {
        $expanded = [System.Environment]::ExpandEnvironmentVariables($p)
        if (Test-Path $expanded) {
            return $expanded
        }
    }
    return $null
}

$chromePath = Find-ExecutablePath @(
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    "%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"
)
$whitetoolsPath = Find-ExecutablePath @(
    "%LOCALAPPDATA%\Programs\WhiteTools Browser\WhiteTools Browser.exe",
    "%LOCALAPPDATA%\Programs\whitetools-browser\WhiteTools Browser.exe",
    "C:\Program Files\WhiteTools Browser\WhiteTools Browser.exe"
)

$publicIp = Get-PublicIP
$hostname = $env:COMPUTERNAME
$os = (Get-CimInstance Win32_OperatingSystem).Caption
$tz = (Get-TimeZone).Id
$pyVer = & $pythonExe --version 2>&1
try { $nodeVer = (& node --version 2>&1) } catch { $nodeVer = "not found" }
try { $gitVer = (& git --version 2>&1) } catch { $gitVer = "not found" }
$sshdStatus = (Get-Service sshd -ErrorAction SilentlyContinue).Status
$rdpEnabled = (Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
    -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections -eq 0

$accessFile = Join-Path $ProjectRoot "ACCESS_FOR_HERMES.md"

$accessContent = @"
# ACCESS_FOR_HERMES

Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

## VPS

- **Public IP:** $publicIp
- **Hostname:** $hostname
- **OS:** $os
- **Timezone:** $tz
- **Architecture:** $env:PROCESSOR_ARCHITECTURE

## Remote access

- **RDP:** $(if ($rdpEnabled) {"enabled (port 3389)"} else {"disabled"})
- **SSH:** $(if ($sshdStatus -eq "Running") {"enabled (port 22)"} else {"not running"})
- **SSH host:** $publicIp
- **SSH port:** 22
- **SSH username (Hermes):** $hermesUser
- **SSH username (fallback):** Administrator
- **Password:** NOT STORED IN FILES - ask user separately
- **Key auth:** $(if ($sshKeyAdded) {"yes (configured)"} else {"no (password only)"})
- **Test connection:** ``ssh ${hermesUser}@${publicIp}``

## Paths

- **Project root:** $ProjectRoot
- **Python venv:** $venvPath
- **Python exe:** $pythonExe
- **Scripts:** $ProjectRoot\scripts
- **Logs:** $ProjectRoot\logs
- **Screenshots:** $ProjectRoot\screenshots
- **Chrome:** $chromePath
- **WhiteTools:** $(if ($whitetoolsPath) { $whitetoolsPath } else { "not found in standard paths" })
- **Tools:** Python $pyVer / Node $nodeVer / Git $gitVer

## Collector API

- **Status:** ready to start
- **Default URL:** http://127.0.0.1:8765
- **External access:** disabled (localhost only)
- **Auth token:** stored in ``config\.env``, NOT displayed here
- **Start command:** ``powershell $ProjectRoot\scripts\start_collector_api.ps1``
- **Start in background:** ``powershell $ProjectRoot\scripts\start_collector_api.ps1 -Background``

## Scripts

| Script | Purpose |
|---|---|
| ``scripts\check_environment.py`` | JSON-отчёт об окружении (Python, Chrome, packages, paths) |
| ``scripts\screenshot_desktop.py`` | Скриншот desktop -> screenshots/desktop_YYYYMMDD.png |
| ``scripts\list_windows.py`` | Список открытых окон (Chrome / WhiteTools / AdHeart) -> logs/windows.json |
| ``scripts\chrome_debug_check.py`` | Проверка http://127.0.0.1:9222 |
| ``scripts\launch_chrome_debug.ps1`` | Запуск Chrome с remote-debugging-port=9222 |
| ``scripts\setup_check_all.ps1`` | Прогон всех диагностик -> logs\setup_check_*.txt |
| ``scripts\collector_api.py`` | Local FastAPI server (GET /health, POST /screenshot, etc.) |
| ``scripts\start_collector_api.ps1`` | Запуск API (fg или -Background) |
| ``scripts\add_ssh_key.ps1`` | Добавить SSH public key для пользователя |

## Verification

Запусти на VPS чтобы убедиться что всё работает:

\`\`\`powershell
cd $ProjectRoot
.\.venv\Scripts\Activate.ps1
python scripts\check_environment.py
python scripts\screenshot_desktop.py
python scripts\list_windows.py
python scripts\chrome_debug_check.py
\`\`\`

## Hermes Agent - how to connect

### Option A: SSH (recommended)
\`\`\`bash
ssh $hermesUser@$publicIp
# затем на VPS:
cd C:\product-research-agent
.\.venv\Scripts\python.exe scripts\check_environment.py
\`\`\`

### Option B: HTTP API (after starting collector_api.py)

\`\`\`bash
# Health (no auth):
curl http://${publicIp}:8765/health

# Полная диагностика (если auth enabled - добавить -H "Authorization: Bearer <token>"):
curl http://127.0.0.1:8765/run-checks -X POST -H "Content-Type: application/json" -d '{}'

# Скриншот:
curl http://127.0.0.1:8765/screenshot -X POST -o screen.png
\`\`\`

⚠️ API по умолчанию только на 127.0.0.1. Для external access - задать токен в config\.env и поменять ``COLLECTOR_HOST=0.0.0.0``.

## Blockers (что Hermes пока НЕ может)

1. **Screenshot из SSH-сессии может вернуть чёрный экран** - Windows Session Isolation. Workaround: запускать collector_api через Scheduled Task в interactive session пользователя (Run only when user is logged on).
2. **WhiteTools Browser sandbox** - нельзя запустить с --remote-debugging-port, это защищённый Chromium. Workaround: использовать отдельный Chrome через ``launch_chrome_debug.ps1``.
3. **AdHeart авторизация** - требует ручной login через WhiteTools. Workaround: сохранить cookies из WhiteTools profile и подгружать их в Playwright Chromium.
4. **2FA / captchas** - manual action required.

## Next recommended step

1. **Hermes:** подключиться по SSH к $publicIp как $hermesUser
2. **Hermes:** запустить ``python scripts\check_environment.py`` - получить JSON отчёт
3. **Hermes:** запустить ``powershell scripts\start_collector_api.ps1 -Background`` - поднять API
4. **Hermes:** опросить API через ``curl http://127.0.0.1:8765/run-checks -X POST``
5. **Hermes:** на основе env-данных решить - DOM scraping через Chrome CDP / OCR через Tesseract / hybrid

---
*Auto-generated by bootstrap.ps1. Re-run to refresh.*
"@

Set-Content -Path $accessFile -Value $accessContent -Encoding UTF8
Write-Host "[OK] Generated: $accessFile" -ForegroundColor Green
Write-Host ""

# =============================================================================
# Финальная сводка
# =============================================================================
Write-Host ""
Write-Host "===============================================" -ForegroundColor Green
Write-Host " Hermes VPS Setup - DONE                       " -ForegroundColor Green
Write-Host "===============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Public IP:       $publicIp"
Write-Host "RDP:             $(if ($rdpEnabled) {"enabled"} else {"DISABLED"})"
Write-Host "SSH:             $(if ($sshdStatus -eq 'Running') {"running on port 22"} else {"NOT running"})"
Write-Host "Hermes user:     $hermesUser $(if ($userCreated) {"(created now)"} else {"(pre-existing or skipped)"})"
Write-Host "SSH key:         $(if ($sshKeyAdded) {"configured"} else {"NOT set (password auth)"})"
Write-Host "Project root:    $ProjectRoot"
Write-Host "Collector API:   ready, run scripts\start_collector_api.ps1 -Background"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Read: $accessFile"
Write-Host "  2. Test SSH from outside: ssh ${hermesUser}@${publicIp}"
Write-Host "  3. Start Collector API: $ProjectRoot\scripts\start_collector_api.ps1 -Background"
Write-Host "  4. Give Hermes the IP, user, port. Pass password to Hermes via secure channel."
Write-Host ""
