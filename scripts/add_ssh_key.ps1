<#
.SYNOPSIS
    Добавляет SSH публичный ключ для пользователя hermes_worker (или другого).

.DESCRIPTION
    Учитывает особенность OpenSSH on Windows: для аккаунтов в группе
    Administrators ключи кладутся в C:\ProgramData\ssh\administrators_authorized_keys
    (не в личный ~/.ssh/authorized_keys).

    Для обычных пользователей — в их $env:USERPROFILE\.ssh\authorized_keys.

.PARAMETER Username
    Имя пользователя (по умолчанию hermes_worker).

.PARAMETER PublicKey
    Текст публичного ключа (строка starting with ssh-rsa, ssh-ed25519 etc).
    Если не передан — будет запрошен интерактивно.

.PARAMETER DisablePasswordAuth
    Если указан, после добавления ключа отключит парольную авторизацию.
    ⚠️ Используй только после успешной проверки ключа!

.EXAMPLE
    .\add_ssh_key.ps1 -Username hermes_worker -PublicKey "ssh-ed25519 AAAA... user@host"
#>

param(
    [string]$Username = "hermes_worker",
    [string]$PublicKey,
    [switch]$DisablePasswordAuth
)

$ErrorActionPreference = "Stop"

if (-not $PublicKey) {
    Write-Host "Paste SSH public key (single line, e.g. ssh-ed25519 AAAA... comment):"
    $PublicKey = Read-Host
}

$PublicKey = $PublicKey.Trim()
if ($PublicKey -notmatch "^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-)") {
    Write-Host "[ERROR] Invalid public key format. Should start with ssh-rsa, ssh-ed25519, etc." -ForegroundColor Red
    exit 1
}

# Проверить что пользователь существует
$user = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
if (-not $user) {
    Write-Host "[ERROR] User '$Username' not found" -ForegroundColor Red
    exit 1
}

# Проверить группу Administrators
$isAdmin = (Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*\$Username" }) -ne $null

if ($isAdmin) {
    # Admin → administrators_authorized_keys
    $keysFile = "C:\ProgramData\ssh\administrators_authorized_keys"
    Write-Host "[INFO] $Username is Administrator, using $keysFile" -ForegroundColor Cyan

    $sshDir = Split-Path $keysFile -Parent
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }
} else {
    # Standard user → личная папка
    $userProfile = "C:\Users\$Username"
    if (-not (Test-Path $userProfile)) {
        Write-Host "[WARN] $userProfile does not exist. User must log in once first to create profile." -ForegroundColor Yellow
        Write-Host "Try: runas /user:$Username cmd"
        exit 1
    }
    $sshDir = Join-Path $userProfile ".ssh"
    $keysFile = Join-Path $sshDir "authorized_keys"
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }
}

# Добавить ключ (избегая дубликата)
$existing = ""
if (Test-Path $keysFile) {
    $existing = Get-Content $keysFile -Raw
}

if ($existing -match [regex]::Escape($PublicKey)) {
    Write-Host "[INFO] Key already present in $keysFile" -ForegroundColor Yellow
} else {
    Add-Content -Path $keysFile -Value $PublicKey -Encoding ASCII
    Write-Host "[OK] Key added to $keysFile" -ForegroundColor Green
}

# Установить правильные permissions (OpenSSH строго относится к этому)
Write-Host "[INFO] Fixing ACL on $keysFile..." -ForegroundColor Cyan

# Сброс наследования + дать доступ только нужным
icacls $keysFile /inheritance:r | Out-Null
if ($isAdmin) {
    # Administrators + SYSTEM
    icacls $keysFile /grant "Administrators:F" "SYSTEM:F" | Out-Null
} else {
    icacls $keysFile /grant "${Username}:F" "SYSTEM:F" | Out-Null
}

# Для папки .ssh — те же правила
icacls $sshDir /inheritance:r | Out-Null
if ($isAdmin) {
    icacls $sshDir /grant "Administrators:F" "SYSTEM:F" | Out-Null
} else {
    icacls $sshDir /grant "${Username}:F" "SYSTEM:F" | Out-Null
}

Write-Host "[OK] ACL set" -ForegroundColor Green

# Опционально — отключить парольный вход
if ($DisablePasswordAuth) {
    $sshdConfig = "C:\ProgramData\ssh\sshd_config"
    if (Test-Path $sshdConfig) {
        Write-Host "[WARN] Disabling PasswordAuthentication globally in $sshdConfig" -ForegroundColor Yellow
        $content = Get-Content $sshdConfig
        $content = $content | ForEach-Object {
            if ($_ -match "^#?PasswordAuthentication\s+") {
                "PasswordAuthentication no"
            } else {
                $_
            }
        }
        $content | Set-Content $sshdConfig -Encoding ASCII
        Restart-Service sshd
        Write-Host "[OK] sshd restarted. Password auth disabled." -ForegroundColor Green
    } else {
        Write-Host "[ERROR] $sshdConfig not found" -ForegroundColor Red
    }
}

Write-Host "`n[DONE] SSH key configured for $Username" -ForegroundColor Green
Write-Host "Test from Hermes side: ssh $Username@<vps-ip>"
