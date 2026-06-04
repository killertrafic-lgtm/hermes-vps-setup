#!/usr/bin/env python
"""
collector_api.py
Локальный HTTP API для Hermes Agent. По умолчанию слушает 127.0.0.1:8765.

Endpoints:
  GET  /health           — проверка живости
  GET  /env              — данные окружения (как check_environment.py)
  POST /screenshot       — сделать скриншот, вернуть путь и URL
  GET  /windows          — список окон
  GET  /chrome-debug     — статус Chrome с remote debug
  POST /run-checks       — запустить все диагностики, вернуть отчёт

Auth:
  Если HERMES_COLLECTOR_TOKEN установлен в config/.env — требуется
  заголовок Authorization: Bearer <token> для всех endpoints кроме /health.
  По умолчанию (no token) — auth disabled.

Запуск:
  cd C:\\product-research-agent
  .\\.venv\\Scripts\\python.exe scripts\\collector_api.py

Или через uvicorn:
  .\\.venv\\Scripts\\uvicorn.exe scripts.collector_api:app --host 127.0.0.1 --port 8765
"""
import os
import sys
import json
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Header
from fastapi.responses import JSONResponse, FileResponse
from pydantic import BaseModel
from dotenv import load_dotenv

PROJECT_ROOT = Path(r"C:\product-research-agent")
SCRIPTS_DIR = PROJECT_ROOT / "scripts"
LOGS_DIR = PROJECT_ROOT / "logs"
SCREENSHOTS_DIR = PROJECT_ROOT / "screenshots"
CONFIG_DIR = PROJECT_ROOT / "config"

# Загружаем config/.env если есть
env_file = CONFIG_DIR / ".env"
if env_file.exists():
    load_dotenv(env_file)

TOKEN = os.getenv("HERMES_COLLECTOR_TOKEN", "").strip()
HOST = os.getenv("COLLECTOR_HOST", "127.0.0.1")
PORT = int(os.getenv("COLLECTOR_PORT", "8765"))

app = FastAPI(
    title="Hermes Collector API",
    description="Local API for Hermes Agent to control VPS environment",
    version="1.0.0",
)


def verify_token(authorization: Optional[str]):
    """Проверка Bearer token если он установлен в env."""
    if not TOKEN:
        return  # auth disabled
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing Bearer token")
    provided = authorization[7:].strip()
    if provided != TOKEN:
        raise HTTPException(status_code=403, detail="Invalid token")


def run_python_script(name: str, timeout: int = 60):
    """Запустить .py скрипт из scripts/, вернуть JSON-результат."""
    script = SCRIPTS_DIR / name
    if not script.exists():
        return {"ok": False, "error": f"Script {script} not found"}
    try:
        out = subprocess.run(
            [sys.executable, str(script)],
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(PROJECT_ROOT),
        )
        try:
            data = json.loads(out.stdout) if out.stdout.strip() else {}
        except json.JSONDecodeError:
            data = {"raw_stdout": out.stdout}
        data["_returncode"] = out.returncode
        if out.stderr:
            data["_stderr"] = out.stderr[:2000]
        return data
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"Timeout after {timeout}s"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.get("/health")
def health():
    """Без авторизации — для liveness check."""
    return {
        "ok": True,
        "timestamp": datetime.now().isoformat(),
        "service": "hermes-collector-api",
        "version": "1.0.0",
        "auth_required": bool(TOKEN),
    }


@app.get("/env")
def env_check(authorization: Optional[str] = Header(default=None)):
    verify_token(authorization)
    return run_python_script("check_environment.py", timeout=60)


@app.post("/screenshot")
def screenshot(authorization: Optional[str] = Header(default=None)):
    verify_token(authorization)
    data = run_python_script("screenshot_desktop.py", timeout=30)
    if data.get("ok") and data.get("path"):
        data["download_url"] = f"/files/screenshot/{Path(data['path']).name}"
    return data


@app.get("/files/screenshot/{filename}")
def get_screenshot(filename: str, authorization: Optional[str] = Header(default=None)):
    verify_token(authorization)
    safe_name = Path(filename).name  # защита от path traversal
    file_path = SCREENSHOTS_DIR / safe_name
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Screenshot not found")
    return FileResponse(str(file_path), media_type="image/png")


@app.get("/windows")
def windows(authorization: Optional[str] = Header(default=None)):
    verify_token(authorization)
    return run_python_script("list_windows.py", timeout=15)


@app.get("/chrome-debug")
def chrome_debug(authorization: Optional[str] = Header(default=None)):
    verify_token(authorization)
    return run_python_script("chrome_debug_check.py", timeout=10)


class RunChecksRequest(BaseModel):
    include_screenshot: bool = False


@app.post("/run-checks")
def run_checks(req: RunChecksRequest = RunChecksRequest(),
               authorization: Optional[str] = Header(default=None)):
    verify_token(authorization)
    result = {
        "timestamp": datetime.now().isoformat(),
        "checks": {},
    }
    result["checks"]["env"] = run_python_script("check_environment.py", timeout=60)
    result["checks"]["windows"] = run_python_script("list_windows.py", timeout=15)
    result["checks"]["chrome_debug"] = run_python_script("chrome_debug_check.py", timeout=10)
    if req.include_screenshot:
        result["checks"]["screenshot"] = run_python_script("screenshot_desktop.py", timeout=30)
    return result


@app.get("/")
def root():
    return {
        "service": "hermes-collector-api",
        "endpoints": [
            "GET  /health",
            "GET  /env",
            "POST /screenshot",
            "GET  /windows",
            "GET  /chrome-debug",
            "POST /run-checks",
            "GET  /files/screenshot/{filename}",
        ],
        "docs": "/docs",
    }


if __name__ == "__main__":
    import uvicorn
    print(f"Starting Hermes Collector API on http://{HOST}:{PORT}")
    print(f"Auth: {'enabled (Bearer token)' if TOKEN else 'DISABLED (localhost only)'}")
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")
