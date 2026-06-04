# Hermes VPS Setup

Подготовка Windows VPS для управления удалённым **Hermes Agent** — сбор данных из AdHeart через WhiteTools Browser + Chrome remote debugging + локальный HTTP API.

## Quick start

На Windows VPS (Administrator PowerShell):

```powershell
# 1. Установить git если ещё нет (или использовать существующий)
choco install -y git

# 2. Склонировать репо
git clone https://github.com/killertrafic-lgtm/hermes-vps-setup.git C:\hermes-setup
cd C:\hermes-setup

# 3. Разрешить выполнение скриптов и запустить bootstrap
Set-ExecutionPolicy Bypass -Scope Process -Force
.\bootstrap.ps1
```

Скрипт интерактивно спросит:
- Пароль для пользователя `hermes_worker` (не записывается в файлы)
- Добавлять ли пользователя в Administrators
- SSH публичный ключ от Hermes (опционально)

В конце создаст `C:\product-research-agent\ACCESS_FOR_HERMES.md` со всей информацией.

## Структура

```
hermes-vps-setup/
├── bootstrap.ps1                 # Главный скрипт инициализации
├── README.md                     # Этот файл
├── requirements.txt              # Python deps
├── scripts/
│   ├── check_environment.py      # JSON-отчёт об окружении
│   ├── screenshot_desktop.py     # Скриншот через mss
│   ├── list_windows.py           # Список окон (win32gui / PS fallback)
│   ├── chrome_debug_check.py     # Проверка :9222
│   ├── launch_chrome_debug.ps1   # Запуск Chrome с CDP
│   ├── setup_check_all.ps1       # Все проверки → logs/
│   ├── collector_api.py          # FastAPI на 127.0.0.1:8765
│   ├── start_collector_api.ps1   # Запуск API (fg/bg)
│   └── add_ssh_key.ps1           # Добавить SSH key
├── config/
│   └── .env.example              # Конфиг API (token, host, port)
└── docs/
```

## Что делает bootstrap.ps1

1. Создаёт структуру `C:\product-research-agent\{scripts,runs,logs,screenshots,exports,config,docs}`
2. Копирует скрипты репозитория в `C:\product-research-agent\scripts\`
3. Активирует/создаёт Python venv в `C:\product-research-agent\.venv`
4. Устанавливает все пакеты из `requirements.txt` (playwright, mss, pyautogui, fastapi, ...)
5. Скачивает Playwright Chromium (~180 MB)
6. Устанавливает + запускает OpenSSH Server (port 22), добавляет firewall rule
7. Создаёт пользователя `hermes_worker` (пароль интерактивно, не пишется в файлы)
8. Опционально настраивает SSH key auth (с правильными ACL для Windows OpenSSH)
9. Запускает все диагностические проверки → `C:\product-research-agent\logs\setup_check_*.txt`
10. Генерирует `ACCESS_FOR_HERMES.md` с реальными IP/paths/статусами

## Безопасность

- **Пароли никогда не пишутся в файлы** — только в Windows SAM через `New-LocalUser`
- **Firewall не отключается** — только добавляется правило для порта 22
- **Collector API по умолчанию слушает 127.0.0.1** — внешний доступ требует токена в `config\.env`
- **WhiteTools не модифицируется** — bootstrap его только обнаруживает по path
- **SSH ACL для администраторов:** ключи кладутся в `C:\ProgramData\ssh\administrators_authorized_keys` (Windows-specific quirk)

## Использование на стороне Hermes

После `bootstrap.ps1` Hermes Agent может:

```bash
# Подключиться по SSH:
ssh hermes_worker@<vps-ip>

# Получить полную диагностику окружения:
python C:\product-research-agent\scripts\check_environment.py

# Или поднять API и опросить через HTTP:
powershell C:\product-research-agent\scripts\start_collector_api.ps1 -Background

# Затем (с Hermes):
curl http://<vps-ip>:8765/run-checks -X POST -H "Content-Type: application/json" -d '{}'
```

## Параметры bootstrap.ps1

```powershell
# Только диагностика, без создания пользователя и SSH:
.\bootstrap.ps1 -SkipUserCreation -SkipSSH

# Не задавать интерактивных вопросов (для CI):
.\bootstrap.ps1 -NonInteractive

# Кастомный путь проекта:
.\bootstrap.ps1 -ProjectRoot "D:\hermes-project"
```

## Re-run

bootstrap.ps1 идемпотентный — можно безопасно перезапускать. Существующие папки/пользователи/firewall-правила не пересоздаются.

## License

MIT
