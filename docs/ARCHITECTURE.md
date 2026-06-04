# Architecture

## Цели

Дать Hermes Agent (Telegram bot на отдельном Debian VPS) возможность управлять Windows VPS **без RDP / без скриншотов от человека**, для автоматизированного сбора данных из AdHeart через WhiteTools Browser.

## Каналы управления

```
┌──────────────────────┐                   ┌──────────────────────────┐
│   Hermes Agent       │                   │  Windows VPS             │
│   (netcup, Debian)   │                   │  (Ukraine.com.ua)        │
│                      │                   │                          │
│   - Python           │  ssh hermes_worker│  ┌────────────────────┐  │
│   - LLM router       │ ─────────────────►│  │ OpenSSH Server :22 │  │
│   - Telegram         │                   │  └────────────────────┘  │
│                      │                   │            │             │
│                      │                   │            ▼             │
│                      │   HTTP API        │  ┌────────────────────┐  │
│                      │ ─────────────────►│  │ Collector API      │  │
│                      │  :8765            │  │ FastAPI/uvicorn    │  │
│                      │  (with token)     │  │ 127.0.0.1:8765     │  │
│                      │                   │  └─────────┬──────────┘  │
│                      │                   │            │             │
│                      │                   │  ┌─────────▼──────────┐  │
│                      │                   │  │ Python scripts     │  │
│                      │                   │  │ - screenshot       │  │
│                      │                   │  │ - list_windows     │  │
│                      │                   │  │ - chrome_debug     │  │
│                      │                   │  │ - playwright       │  │
│                      │                   │  └─────────┬──────────┘  │
│                      │                   │            │             │
│                      │                   │  ┌─────────▼──────────┐  │
│                      │                   │  │ Chrome :9222 (CDP) │  │
│                      │                   │  │ WhiteTools Browser │  │
│                      │                   │  │ AdHeart            │  │
│                      │                   │  └────────────────────┘  │
└──────────────────────┘                   └──────────────────────────┘
```

## Два режима связи

### Mode A: SSH (text commands)
- Hermes делает `ssh hermes_worker@<vps-ip> "powershell -Command ..."`
- Получает stdout
- Используется для системных команд, простых проверок, restart-ов

**Limitation:** SSH non-interactive session = Session 0 в Windows. Не видит desktop, не делает реальный screenshot.

### Mode B: HTTP API (structured)
- Collector API запущен в Session 1 (interactive desktop) через Scheduled Task
- Hermes делает `curl http://<vps-ip>:8765/screenshot -H "Authorization: Bearer ..."`
- API делает реальный скриншот в своей сессии и отдаёт PNG
- Используется для screenshot / window listing / визуальных проверок

**Setup:** для production — API должен стартовать через Task Scheduler с триггером "At log on of user Administrator" + "Run only when user is logged on".

## Сбор данных из AdHeart — стратегии

### Strategy 1: Pure Playwright + cookie reuse
1. Илья один раз заходит в WhiteTools → AdHeart → авторизуется
2. WhiteTools хранит cookies в его профиле (отдельный Chromium-based)
3. Скрипт экспортирует cookies из WhiteTools profile
4. Playwright Chromium запускается с этими cookies → парсит AdHeart

**Плюсы:** автономно после первого логина
**Минусы:** cookies expire, AdHeart может различить fingerprints Playwright vs WhiteTools

### Strategy 2: Chrome CDP (controlled Chrome)
1. Запускаем обычный Chrome с `--remote-debugging-port=9222`
2. В нём через CDP открываем AdHeart
3. Hermes управляет через WebSocket
4. **Авторизация остаётся manual** (one-time через RDP)

**Плюсы:** легче в управлении, без WhiteTools-сложности
**Минусы:** AdHeart может банить обычный Chrome без anti-detect

### Strategy 3: OCR screenshots
1. WhiteTools открыт визуально (Илья оставил interactive session)
2. Hermes делает screenshot через Collector API
3. Tesseract / OpenCV выделяет данные креативов
4. Hermes сохраняет/анализирует

**Плюсы:** работает с любым browser, обходит antibot
**Минусы:** медленно, ошибки OCR, нельзя массово

### Strategy 4: Hybrid (recommended for v1)
- **Discovery** через screenshots + OCR (1-2 раза в день, минут 5)
- **Detail scraping** через Chrome CDP по уже найденным URL
- **Manual login** один раз через RDP, дальше всё автоматически

## Безопасность

- `hermes_worker` — отдельный аккаунт. Если компрометируется — изоляция от Administrator
- SSH key auth предпочтительнее password
- Collector API внутри VPS (127.0.0.1) — нет сети наружу без токена
- Если открывать API наружу — обязательный Bearer token (минимум 32 байт случайных)
- Никаких credentials в git репо (`.env` в `.gitignore`)

## Next milestones

- [ ] M1: bootstrap.ps1 запускается на VPS без ошибок (текущий milestone)
- [ ] M2: Hermes по SSH получает check_environment.json
- [ ] M3: Collector API стартует как Scheduled Task (background, no manual launch)
- [ ] M4: Hermes получает первый screenshot через API
- [ ] M5: Первый успешный CDP-запуск Chrome с AdHeart open
- [ ] M6: Cookie export из WhiteTools → import в Playwright
- [ ] M7: Первый автоматический сбор 10 креативов в `runs/YYYY-MM-DD/`
- [ ] M8: Cron / Task Scheduler — ежедневный автозапуск
