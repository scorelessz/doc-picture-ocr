#!/usr/bin/env python3
"""给 PyInstaller 用的入口脚本(`pyinstaller app/launcher.py`)。

PyInstaller 的入口脚本是以 `__main__` 跑的, 相对 import 用不了 —— 所以这里
只做一件事: 保证 `app` 这个包能 import 到, 然后转给 app.main.main()。
开发态直接 `python app/launcher.py` 也是一样的效果。
"""
from __future__ import annotations

import sys
from pathlib import Path

try:
    from app.main import main
except ImportError:                       # 开发态直接跑这个文件: 补上项目根
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from app.main import main


if __name__ == "__main__":
    raise SystemExit(main())
