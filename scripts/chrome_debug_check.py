#!/usr/bin/env python
"""
chrome_debug_check.py
Проверка что Chrome запущен с remote debugging port 9222.

Подключается к http://127.0.0.1:9222/json/version, выводит JSON или ошибку.
"""
import sys
import io
import json
from datetime import datetime
from pathlib import Path

# Force UTF-8 stdout (Windows console defaults to cp1252)
if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

try:
    import requests
except ImportError:
    print(json.dumps({
        "ok": False,
        "error": "requests not installed (pip install requests)",
    }))
    sys.exit(1)

PROJECT_ROOT = Path(r"C:\product-research-agent")
LOGS_DIR = PROJECT_ROOT / "logs"

DEBUG_PORT = 9222
DEBUG_HOST = "127.0.0.1"
TIMEOUT = 5


def check_endpoint(path):
    url = f"http://{DEBUG_HOST}:{DEBUG_PORT}{path}"
    try:
        r = requests.get(url, timeout=TIMEOUT)
        r.raise_for_status()
        return {"url": url, "status": r.status_code, "json": r.json()}
    except requests.exceptions.ConnectionError:
        return {
            "url": url,
            "error": "connection_refused",
            "hint": "Chrome with --remote-debugging-port not running. "
                    "Run: powershell scripts\\launch_chrome_debug.ps1",
        }
    except Exception as e:
        return {"url": url, "error": str(e)}


def main():
    LOGS_DIR.mkdir(parents=True, exist_ok=True)

    result = {
        "timestamp": datetime.now().isoformat(),
        "debug_url": f"http://{DEBUG_HOST}:{DEBUG_PORT}",
        "checks": {},
        "ok": False,
    }

    version = check_endpoint("/json/version")
    result["checks"]["/json/version"] = version

    if "json" in version:
        result["ok"] = True
        targets = check_endpoint("/json")
        result["checks"]["/json"] = targets
        if "json" in targets:
            result["targets_count"] = len(targets["json"])
            result["targets"] = [
                {
                    "type": t.get("type"),
                    "title": t.get("title"),
                    "url": t.get("url"),
                    "webSocketDebuggerUrl": t.get("webSocketDebuggerUrl"),
                }
                for t in targets["json"][:10]  # первые 10
            ]

    out_path = LOGS_DIR / "chrome_debug_check.json"
    try:
        out_path.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
        result["_saved_to"] = str(out_path)
    except Exception as e:
        result["_save_error"] = str(e)

    print(json.dumps(result, indent=2, ensure_ascii=False))
    sys.exit(0 if result["ok"] else 1)


if __name__ == "__main__":
    main()
