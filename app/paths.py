#!/usr/bin/env python3
"""资源定位 —— 开发态(项目目录)和打包态(.app 里的 Resources)用同一套调用。

打包的人只需要保证这三样东西被原样拷进包里, **保持相对路径**:

    src/            书籍线的 book_*.py / run_books.py(作为**数据**拷贝, 不要冻结成模块)
    bin/vision-ocr  Swift 编的 Vision 识别器, 必须保留可执行位
    config/         glossary.txt 等(可选, 术语表默认不启用)

`src/` 必须作为数据目录拷贝而不是让 PyInstaller 冻结: book_render.py 里
`ROOT = Path(__file__).resolve().parent.parent`, 冻结后 `__file__` 落在打包归档里,
那个 ROOT 指不到真实磁盘路径, `bin/vision-ocr` 就找不着。作为数据目录拷贝 +
运行时 `sys.path.insert` 则一切照旧。`patch_engine_paths()` 另外把 VISION_BIN
显式钉死, 即使布局变了也还能活。

覆盖搜索顺序的后门: 环境变量 `OCR_RESOURCE_ROOT` 指到一个目录, 一切以它为准
(打包验收和 `--selftest` 用得上)。
"""
from __future__ import annotations

import os
import stat
import sys
from pathlib import Path

#  app/ 的上一级 = 开发态的项目根
_DEV_ROOT = Path(__file__).resolve().parent.parent


def _candidates() -> list[Path]:
    """可能的资源根, 按优先级。只返回存在的目录。"""
    out: list[Path] = []

    def add(p: Path | None) -> None:
        if p is None:
            return
        try:
            p = Path(p).resolve()
        except OSError:
            return
        if p.is_dir() and p not in out:
            out.append(p)

    env = os.environ.get("OCR_RESOURCE_ROOT")
    if env:
        add(Path(env).expanduser())

    #  PyInstaller: onedir/onefile 都设 sys._MEIPASS。macOS .app 里 PyInstaller 6
    #  把二进制放 Contents/Frameworks、数据放 Contents/Resources, 两边互相软链,
    #  所以 _MEIPASS 和 ../Resources 都要试。
    meipass = getattr(sys, "_MEIPASS", None)
    add(Path(meipass) if meipass else None)

    if getattr(sys, "frozen", False):
        exe = Path(sys.executable).resolve()
        add(exe.parent)                       # Contents/MacOS
        add(exe.parent.parent / "Resources")  # Contents/Resources
        add(exe.parent.parent / "Frameworks")

    add(_DEV_ROOT)
    return out


_ROOTS = _candidates()


def resource_root() -> Path:
    """资源根目录。找不到任何候选时退回开发态项目根(让报错信息指向人看得懂的地方)。"""
    for r in _ROOTS:
        if (r / "src" / "run_books.py").is_file():
            return r
    return _ROOTS[0] if _ROOTS else _DEV_ROOT


def resource_path(*parts: str) -> Path:
    """定位随程序分发的只读资源。

    参数是相对项目根的路径片段, 如 resource_path("bin", "vision-ocr") 或
    resource_path("bin/vision-ocr") —— 两种写法等价。

    行为: 按 OCR_RESOURCE_ROOT → sys._MEIPASS → .app 的 MacOS/Resources/Frameworks
    → 开发态项目根的顺序找**第一个真实存在**的, 返回绝对 Path。
    一个都不存在时返回「首选根 + 相对路径」这个不存在的 Path —— 调用方照常
    .exists() 判断, 报错信息里的路径也是人能看懂的那个。不抛异常, 不做 I/O 写入。
    不带参数调用 = 返回资源根本身。
    """
    rel = Path(*parts) if parts else Path()
    if rel.is_absolute():
        return rel
    for r in _ROOTS:
        p = r / rel
        if p.exists():
            return p
    return resource_root() / rel


def src_dir() -> Path:
    return resource_path("src")


def vision_bin() -> Path:
    return resource_path("bin", "vision-ocr")


_bootstrapped = False


def bootstrap() -> Path:
    """把 src/ 放进 sys.path, 并把引擎里写死的路径钉到真实资源上。

    返回资源根。可重复调用(幂等)。import 书籍线任何模块**之前**必须先调它。
    """
    global _bootstrapped
    root = resource_root()
    s = str(src_dir())
    if s not in sys.path:
        sys.path.insert(0, s)
    if not _bootstrapped:
        _bootstrapped = True
        _ensure_executable(vision_bin())
    return root


def patch_engine_paths() -> None:
    """import book_engines **之后**调: 把 VISION_BIN 钉死到 resource_path()。

    book_engines 自己按 `src/../bin/vision-ocr` 推, 开发态和「src 作为数据目录
    拷进 Resources」的打包态都对。这里只是上保险: 万一打包布局变了(比如 src
    被冻结), 这一步仍然能把路径救回来。找不到就不动, 让原来的报错照常出现。
    """
    v = vision_bin()
    if not v.exists():
        return
    try:
        import book_engines
    except ImportError:
        return
    book_engines.VISION_BIN = v
    _ensure_executable(v)


def _ensure_executable(p: Path) -> None:
    """拷贝/解压可能丢可执行位 —— 丢了就补上。不是我们的文件就算了。"""
    try:
        if p.is_file() and not os.access(p, os.X_OK):
            p.chmod(p.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    except OSError:
        pass


# ---------------------------------------------------------------- 用户数据

APP_NAME = "DocPictureOCR"


def user_data_dir() -> Path:
    """可写的用户目录。**绝不写进项目目录** —— 项目可能是只读的 .app 内部。"""
    base = Path.home() / "Library" / "Application Support" / APP_NAME
    base.mkdir(parents=True, exist_ok=True)
    return base


def default_outdir() -> Path:
    """默认输出目录。

    **不是**项目的 output/: 打包后 .app 内部不可写, 而开发态下项目 output/ 是
    剧本线和别的会话的输入(CLAUDE.md 的多 fork 约定)。GUI 一律往用户自己的
    文档目录写, 中间产物进 <outdir>/work。
    """
    return Path.home() / "Documents" / "OCR 输出"


def describe() -> str:
    """给日志/排错用的一行环境说明。"""
    return (f"资源根 {resource_root()}   "
            f"frozen={bool(getattr(sys, 'frozen', False))}   "
            f"vision-ocr={'有' if vision_bin().exists() else '缺!'}")
