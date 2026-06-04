#!/usr/bin/env python
"""
screenshot_desktop.py
Скриншот всего экрана (всех мониторов), сохраняет в screenshots/.

Используется mss (быстрее и реалистичнее чем pyautogui).

LIMITATION:
Если скрипт запущен из Session 0 (SSH non-interactive shell) — скриншот
может вернуть пустой/чёрный экран из-за Windows Session Isolation.
Workaround: запускать collector_api как Scheduled Task с
"Run only when user is logged on" → API будет в Session 1.
"""
import sys
import io
import os
import json
from datetime import datetime
from pathlib import Path

# Force UTF-8 stdout (Windows console defaults to cp1252)
if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

try:
    import mss
    import mss.tools
    HAS_MSS = True
except ImportError:
    HAS_MSS = False

try:
    import pyautogui
    HAS_PYAUTOGUI = True
except ImportError:
    HAS_PYAUTOGUI = False

PROJECT_ROOT = Path(r"C:\product-research-agent")
SCREENSHOTS_DIR = PROJECT_ROOT / "screenshots"


def take_screenshot_mss(out_path: Path):
    with mss.mss() as sct:
        # Monitor 0 = все мониторы вместе
        monitor = sct.monitors[0]
        sct_img = sct.grab(monitor)
        mss.tools.to_png(sct_img.rgb, sct_img.size, output=str(out_path))
    return {
        "method": "mss",
        "width": monitor["width"],
        "height": monitor["height"],
    }


def take_screenshot_pyautogui(out_path: Path):
    img = pyautogui.screenshot()
    img.save(str(out_path))
    return {
        "method": "pyautogui",
        "width": img.width,
        "height": img.height,
    }


def main():
    SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = SCREENSHOTS_DIR / f"desktop_{timestamp}.png"

    result = {
        "timestamp": datetime.now().isoformat(),
        "ok": False,
    }

    try:
        if HAS_MSS:
            meta = take_screenshot_mss(out_path)
        elif HAS_PYAUTOGUI:
            meta = take_screenshot_pyautogui(out_path)
        else:
            raise RuntimeError("Neither mss nor pyautogui installed")

        size_bytes = out_path.stat().st_size if out_path.exists() else 0
        result.update({
            "ok": True,
            "path": str(out_path),
            "size_bytes": size_bytes,
            **meta,
        })

        # Heuristic: если файл < 1KB или = одноцветный, вероятно Session 0 issue
        if size_bytes < 1024:
            result["warning"] = (
                "Screenshot size < 1KB. Likely Session 0 issue. "
                "Run collector_api via Scheduled Task in interactive session."
            )
    except Exception as e:
        result["error"] = str(e)

    print(json.dumps(result, indent=2, ensure_ascii=False))
    sys.exit(0 if result["ok"] else 1)


if __name__ == "__main__":
    main()
