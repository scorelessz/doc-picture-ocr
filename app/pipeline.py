#!/usr/bin/env python3
"""GUI ↔ 流水线之间的那一层: 建 Config、开工作线程、把事件和日志送回去。

**全部在进程内 import 跑**, 不 subprocess 调 python —— 打包后包里没有
python 解释器可调。所有书籍线模块的 import 都推迟到 bootstrap() 之后,
因为 sys.path 要先指向打包态的 src/。

线程模型: 一个批次 = 一个工作线程。Tk 不是线程安全的, 所以这里**不碰任何
Tk 对象**, 只往 `queue.Queue` 里塞事件 dict, 由 GUI 线程 after() 轮询取走。

日志: 书籍线的所有模块都 print 到 sys.stderr(run_books.log / book_md 等各有
各的), 没有统一的 logger。所以这里在工作线程期间把 sys.stderr 整个换掉, 逐行
变成 {"type":"log"} 事件。换的是全局的 sys.stderr —— 同一时间只允许跑一个批次,
GUI 用按钮状态保证这一点。
"""
from __future__ import annotations

import contextlib
import io
import queue
import threading
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from .paths import bootstrap, patch_engine_paths

#  阶段的显示名 + 在单份进度条里占的权重(按真书 373 页实测耗时的粗略比例:
#  OCR 压倒性地长, 其余三步加起来不到一成)。
STAGES: list[tuple[str, str, float]] = [
    ("ocr", "渲染 + OCR", 0.88),
    ("fuse", "双引擎融合", 0.03),
    ("markdown", "段落化 Markdown", 0.04),
    ("embed", "可搜索 PDF", 0.05),
]
STAGE_LABEL = {k: v for k, v, _ in STAGES}
_STAGE_BASE: dict[str, tuple[float, float]] = {}
_acc = 0.0
for _k, _v, _w in STAGES:
    _STAGE_BASE[_k] = (_acc, _w)
    _acc += _w


def stage_fraction(stage: str | None, done: int = 0, total: int = 0) -> float:
    """某份文件走到 stage(OCR 内第 done/total 页)时, 这一份完成了多少。0~1。"""
    if stage is None:
        return 0.0
    base, w = _STAGE_BASE.get(stage, (0.0, 0.0))
    inner = (done / total) if (stage == "ocr" and total) else 0.0
    return min(1.0, base + w * inner)


# ---------------------------------------------------------------- 作业配置

@dataclass
class Job:
    """一次「点下开始」的全部输入。字段名对齐 run_books.Config / CLI 开关。"""
    files: list[Path]
    outdir: Path
    workdir: Path | None = None      # None = <outdir>/work
    dpi: float = 300.0
    max_dpi: float | None = None
    native_dpi: bool = True
    engine: str = "both"
    jobs: int | None = None
    pages: str | None = None
    force: bool = False              # 已存在产物: 重做
    resume: bool = False             # 已存在产物: 续跑
    keep_pages: bool = False
    page_marks: bool = True
    force_ocr: bool = False
    allow_repaired: bool = False
    glossary: Path | None = None
    extra: dict[str, Any] = field(default_factory=dict)

    def effective_workdir(self) -> Path:
        return self.workdir or (self.outdir / "work")


def build_config(job: Job):
    """Job -> run_books.Config。import 在函数内, 保证 bootstrap() 已经跑过。"""
    import run_books
    from postcheck import load_glossary

    gpath, rules = None, []
    if job.glossary:
        gpath = Path(job.glossary).expanduser()
        if not gpath.is_file():
            raise FileNotFoundError(f"术语表不存在: {gpath}")
        rules = load_glossary(gpath)

    return run_books.Config(
        input=job.outdir,                      # run_batch 给显式清单, 用不到
        outdir=Path(job.outdir).expanduser().resolve(),
        workdir=Path(job.effective_workdir()).expanduser().resolve(),
        dpi=job.dpi, jobs=job.jobs or None, engine=job.engine,
        native_dpi=job.native_dpi,
        max_dpi=job.max_dpi if job.max_dpi else None,
        pages=job.pages or None,
        force_ocr=job.force_ocr, allow_repaired=job.allow_repaired,
        force=job.force, resume=job.resume, clobber=False,
        keep_pages=job.keep_pages, page_marks=job.page_marks,
        glossary_path=gpath, glossary=rules,
    )


# ---------------------------------------------------------------- stderr 转事件

class _LineSink(io.TextIOBase):
    """把 write() 的字节流按行切开, 逐行回调。不缓冲整批(几百页会很长)。"""

    def __init__(self, emit: Callable[[str], None]) -> None:
        self._emit = emit
        self._buf = ""

    def writable(self) -> bool:
        return True

    def write(self, s: str) -> int:
        if not s:
            return 0
        self._buf += s
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            self._emit(line)
        if len(self._buf) > 8192:            # 没有换行的巨长行: 截断送出
            self._emit(self._buf)
            self._buf = ""
        return len(s)

    def flush(self) -> None:
        if self._buf:
            self._emit(self._buf)
            self._buf = ""


# ---------------------------------------------------------------- 运行器

class Runner:
    """一个批次的工作线程。事件进 self.events(queue.Queue), GUI 自己来取。

    事件契约 = run_books.run_batch 的那一套, 外加本层新增的两类:
      log    {"type":"log", "line": str}          流水线写到 stderr 的每一行
      crash  {"type":"crash", "error": str, "traceback": str}
                                                  整批崩了(不是单份失败)
    这两类之外的事件原样来自 run_batch, 字段见它的 docstring。
    """

    def __init__(self, job: Job) -> None:
        self.job = job
        self.events: queue.Queue[dict] = queue.Queue()
        self._cancel = threading.Event()
        self._thread: threading.Thread | None = None
        self.started_at = 0.0

    # -- 控制 ------------------------------------------------------
    def start(self) -> None:
        if self._thread is not None:
            raise RuntimeError("这个 Runner 已经跑过了, 每批新建一个")
        self.started_at = time.time()
        self._thread = threading.Thread(target=self._run, name="ocr-batch",
                                        daemon=True)
        self._thread.start()

    def cancel(self) -> None:
        self._cancel.set()

    @property
    def cancelled(self) -> bool:
        return self._cancel.is_set()

    def is_alive(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def join(self, timeout: float | None = None) -> None:
        if self._thread is not None:
            self._thread.join(timeout)

    # -- 线程体 ----------------------------------------------------
    def _put(self, ev: dict) -> None:
        self.events.put(ev)

    def _log(self, line: str) -> None:
        self._put({"type": "log", "line": line})

    def _run(self) -> None:
        sink = _LineSink(self._log)
        try:
            with contextlib.redirect_stderr(sink):
                try:
                    self._body()
                finally:
                    sink.flush()
        except BaseException as e:            # noqa: BLE001 线程里崩了也要报出去
            self._put({"type": "crash", "error": f"{type(e).__name__}: {e}",
                       "traceback": traceback.format_exc()})

    def _body(self) -> None:
        bootstrap()
        import run_books
        patch_engine_paths()

        from .paths import describe
        print(describe())

        cfg = build_config(self.job)
        run_books.run_batch(cfg, [Path(f) for f in self.job.files],
                            on_event=self._put,
                            should_cancel=self._cancel.is_set)


# ---------------------------------------------------------------- 同步跑一批

def run_sync(job: Job, on_event: Callable[[dict], None] | None = None) -> dict:
    """不开线程、不要界面地跑一批。--selftest 和脚本调用走这条。

    返回 run_batch 的 summary dict。日志照常去 stderr(不劫持)。
    """
    bootstrap()
    import run_books
    patch_engine_paths()
    cfg = build_config(job)
    return run_books.run_batch(cfg, [Path(f) for f in job.files],
                               on_event=on_event)
