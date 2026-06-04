#!/usr/bin/env python
"""
check_environment.py
Проверка окружения Windows VPS для Hermes Agent.
Выводит JSON-результат в stdout, дублирует в logs/check_environment.json.
"""
import sys
import os
import json
import platform
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

REQUIRED_PACKAGES = [
    "playwright",
    "requests",
    "pandas",
    "PIL",
    "cv2",
    "bs4",
    "lxml",
    "pyautogui",
    "pytesseract",
    "dotenv",
    "fastapi",
    "uvicorn",
    "psutil",
    "mss",
]

# Опциональные (pywinauto на Linux fails, на Windows ОК)
OPTIONAL_PACKAGES = [
    "pywinauto",
]

CHROME_CANDIDATE_PATHS = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"),
]

WHITETOOLS_CANDIDATE_PATHS = [
    os.path.expandvars(r"%LOCALAPPDATA%\Programs\WhiteTools Browser\WhiteTools Browser.exe"),
    os.path.expandvars(r"%LOCALAPPDATA%\Programs\whitetools-browser\WhiteTools Browser.exe"),
    r"C:\Program Files\WhiteTools Browser\WhiteTools Browser.exe",
    r"C:\Program Files (x86)\WhiteTools Browser\WhiteTools Browser.exe",
]

PROJECT_ROOT = Path(r"C:\product-research-agent")
REQUIRED_SUBDIRS = ["scripts", "runs", "logs", "screenshots", "exports", "config", "docs"]


def check_packages(packages, optional=False):
    results = {}
    for pkg in packages:
        try:
            __import__(pkg)
            mod = sys.modules.get(pkg)
            version = getattr(mod, "__version__", "unknown") if mod else "unknown"
            results[pkg] = {"installed": True, "version": str(version), "optional": optional}
        except Exception as e:
            results[pkg] = {"installed": False, "error": str(e), "optional": optional}
    return results


def find_executable(candidates):
    for path in candidates:
        if path and os.path.isfile(path):
            return path
    return None


def check_writable(path: Path):
    try:
        path.mkdir(parents=True, exist_ok=True)
        test_file = path / ".write_test"
        test_file.write_text("test")
        test_file.unlink()
        return True
    except Exception:
        return False


def get_external_ip():
    try:
        import urllib.request
        return urllib.request.urlopen("https://api.ipify.org", timeout=5).read().decode().strip()
    except Exception as e:
        return f"error: {e}"


def get_tool_version(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=10, shell=True)
        return (out.stdout + out.stderr).strip().split("\n")[0]
    except Exception as e:
        return f"error: {e}"


def main():
    result = {
        "timestamp": datetime.now().isoformat(),
        "host": platform.node(),
        "os": {
            "system": platform.system(),
            "release": platform.release(),
            "version": platform.version(),
            "machine": platform.machine(),
        },
        "python": {
            "version": sys.version,
            "executable": sys.executable,
            "prefix": sys.prefix,
            "in_venv": sys.prefix != sys.base_prefix,
        },
        "user": os.environ.get("USERNAME") or os.environ.get("USER"),
        "cwd": os.getcwd(),
        "timezone": str(datetime.now().astimezone().tzinfo),
        "external_ip": get_external_ip(),
        "tools": {
            "git": get_tool_version("git --version"),
            "node": get_tool_version("node --version"),
            "npm": get_tool_version("npm --version"),
            "choco": get_tool_version("choco --version"),
        },
        "chrome_path": find_executable(CHROME_CANDIDATE_PATHS),
        "whitetools_path": find_executable(WHITETOOLS_CANDIDATE_PATHS),
        "project_root": str(PROJECT_ROOT),
        "project_root_exists": PROJECT_ROOT.exists(),
        "subdirs": {
            sub: {
                "exists": (PROJECT_ROOT / sub).exists(),
                "writable": check_writable(PROJECT_ROOT / sub),
            }
            for sub in REQUIRED_SUBDIRS
        },
        "packages": {
            **check_packages(REQUIRED_PACKAGES, optional=False),
            **check_packages(OPTIONAL_PACKAGES, optional=True),
        },
    }

    # Сводка
    pkg_missing = [k for k, v in result["packages"].items() if not v["installed"] and not v.get("optional")]
    result["summary"] = {
        "ok": (
            result["chrome_path"] is not None
            and result["project_root_exists"]
            and len(pkg_missing) == 0
        ),
        "missing_required_packages": pkg_missing,
        "chrome_found": result["chrome_path"] is not None,
        "whitetools_found": result["whitetools_path"] is not None,
    }

    # Сохранить в logs
    logs_dir = PROJECT_ROOT / "logs"
    if logs_dir.exists() or check_writable(logs_dir):
        out_file = logs_dir / "check_environment.json"
        try:
            out_file.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
            result["_saved_to"] = str(out_file)
        except Exception as e:
            result["_save_error"] = str(e)

    print(json.dumps(result, indent=2, ensure_ascii=False))
    sys.exit(0 if result["summary"]["ok"] else 1)


if __name__ == "__main__":
    main()
