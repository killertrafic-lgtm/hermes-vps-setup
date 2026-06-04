#!/usr/bin/env python
"""
list_windows.py
Список открытых окон на Desktop с фокусом на Chrome / WhiteTools / AdHeart.

Стратегия:
1. Сначала пробуем через win32gui (через pywin32 если есть) — самый надёжный
2. Fallback на PowerShell Get-Process с MainWindowTitle
3. Сохраняем JSON в logs/windows.json

LIMITATION: список окон видит только Session текущего пользователя.
Из Session 0 (SSH non-interactive) увидит только Session 0 окна.
"""
import sys
import os
import json
import subprocess
from datetime import datetime
from pathlib import Path

PROJECT_ROOT = Path(r"C:\product-research-agent")
LOGS_DIR = PROJECT_ROOT / "logs"

TARGET_KEYWORDS = [
    "chrome",
    "whitetools",
    "adheart",
    "google chrome",
    "white tools",
]


def list_windows_win32():
    """Использует win32gui если pywin32 установлен."""
    try:
        import win32gui
        import win32process
        import psutil
    except ImportError:
        return None

    windows = []

    def enum_handler(hwnd, _):
        if not win32gui.IsWindowVisible(hwnd):
            return
        title = win32gui.GetWindowText(hwnd)
        if not title:
            return
        try:
            _, pid = win32process.GetWindowThreadProcessId(hwnd)
            proc_name = psutil.Process(pid).name() if pid else None
        except Exception:
            pid = None
            proc_name = None
        windows.append({
            "hwnd": hwnd,
            "title": title,
            "pid": pid,
            "process": proc_name,
        })

    win32gui.EnumWindows(enum_handler, None)
    return windows


def list_windows_powershell():
    """Fallback на PowerShell."""
    cmd = [
        "powershell",
        "-NoProfile",
        "-Command",
        "Get-Process | Where-Object { $_.MainWindowTitle -ne '' } | "
        "Select-Object Id, ProcessName, MainWindowTitle | ConvertTo-Json",
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if out.returncode != 0:
            return None
        data = json.loads(out.stdout) if out.stdout.strip() else []
        # PowerShell ConvertTo-Json для одного объекта возвращает не массив
        if isinstance(data, dict):
            data = [data]
        return [
            {
                "pid": item.get("Id"),
                "process": item.get("ProcessName"),
                "title": item.get("MainWindowTitle"),
            }
            for item in data
        ]
    except Exception:
        return None


def find_targets(windows):
    """Фильтр окон по ключевым словам."""
    found = {kw: [] for kw in ["chrome", "whitetools", "adheart"]}
    for w in windows:
        title = (w.get("title") or "").lower()
        proc = (w.get("process") or "").lower()
        if "chrome" in title or "chrome" in proc:
            found["chrome"].append(w)
        if "whitetools" in title or "whitetools" in proc or "white tools" in title:
            found["whitetools"].append(w)
        if "adheart" in title:
            found["adheart"].append(w)
    return found


def main():
    LOGS_DIR.mkdir(parents=True, exist_ok=True)

    result = {
        "timestamp": datetime.now().isoformat(),
        "method": None,
        "windows": [],
        "targets": {},
        "ok": False,
    }

    windows = list_windows_win32()
    if windows is not None:
        result["method"] = "win32gui"
    else:
        windows = list_windows_powershell()
        if windows is not None:
            result["method"] = "powershell"

    if windows is None:
        result["error"] = "Both win32gui and PowerShell methods failed"
    else:
        result["windows"] = windows
        result["targets"] = find_targets(windows)
        result["ok"] = True

    out_path = LOGS_DIR / "windows.json"
    try:
        out_path.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
        result["_saved_to"] = str(out_path)
    except Exception as e:
        result["_save_error"] = str(e)

    print(json.dumps(result, indent=2, ensure_ascii=False))
    sys.exit(0 if result["ok"] else 1)


if __name__ == "__main__":
    main()
