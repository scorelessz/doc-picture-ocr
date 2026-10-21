#!/usr/bin/env python3
"""参数持久化: ~/Library/Application Support/DocPictureOCR/settings.json

**不写进项目目录** —— 打包后 .app 内部只读, 且项目目录是多个会话共用的。
读写都兜底: 文件坏了/没权限一律退回默认值, 绝不让界面因为一份 json 打不开。
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .paths import default_outdir, user_data_dir

#  键名与 run_books.Config / CLI 开关一一对应, 方便对照 BOOKS.md。
DEFAULTS: dict[str, Any] = {
    "outdir": "",                 # 空 = default_outdir()
    "dpi": 300.0,
    "max_dpi": 0.0,               # 0 = 不限(用 book_render 的 MAX_DPI)
    "native_dpi": True,           # False 等于 CLI 的 --no-native-dpi
    "engine": "both",             # both | vision | rapidocr
    "jobs": 0,                    # 0 = 自动
    "on_exist": "skip",           # skip | redo(--force) | resume(--resume)
    "pages": "",                  # "" | "N" | "A-B"
    "glossary": "",               # 空 = 不启用(BOOKS.md: 默认关, 剧本表会改错书)
    "force_ocr": False,
    "keep_pages": False,
    "page_marks": True,
    "allow_repaired": False,
    "window": "",                 # "WxH+X+Y"
    "params_open": False,         # 参数区是否展开
    "log_open": False,            # 日志区是否展开
    "last_dir": "",               # 上次选文件的目录
}


def _path() -> Path:
    return user_data_dir() / "settings.json"


def load() -> dict[str, Any]:
    d = dict(DEFAULTS)
    try:
        raw = json.loads(_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return d
    if not isinstance(raw, dict):
        return d
    for k, v in raw.items():
        if k not in DEFAULTS:
            continue                       # 老版本留下的垃圾键直接忽略
        want = type(DEFAULTS[k])
        if want is float and isinstance(v, int):
            v = float(v)
        if isinstance(v, want):
            d[k] = v
    return d


def save(d: dict[str, Any]) -> None:
    try:
        p = _path()
        tmp = p.with_suffix(".json.part")
        tmp.write_text(json.dumps({k: d.get(k, DEFAULTS[k]) for k in DEFAULTS},
                                  ensure_ascii=False, indent=2),
                       encoding="utf-8")
        tmp.replace(p)                     # 原子写: 写一半断电不会留下坏 json
    except OSError:
        pass                               # 存不下参数不该拖垮一次 OCR


def resolved_outdir(d: dict[str, Any]) -> Path:
    s = str(d.get("outdir") or "").strip()
    return Path(s).expanduser() if s else default_outdir()
