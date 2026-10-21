#!/usr/bin/env python3
"""入口。

    .venv/bin/python -m app                      开界面
    .venv/bin/python -m app --selftest a.pdf     无界面跑完整流水线, 打印事件流
    .venv/bin/python -m app --cli -- --help      直接转给书籍线 CLI(run_books.py)

--selftest 是**打包之后唯一能在命令行验证整条链路**的办法: 打成 .app 以后
没有 python 可调, 只能 `OCR.app/Contents/MacOS/OCR --selftest 某.pdf`。
它走的是和界面完全相同的代码路径(同一个 Job / build_config / run_batch),
只是不开 Tk —— 所以它过了就说明资源定位、引擎、四个阶段都是通的。
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path


def _selftest(argv: list[str]) -> int:
    from . import pipeline
    from .paths import describe, resource_path, vision_bin

    ap = argparse.ArgumentParser(prog="--selftest",
                                 description="无界面跑一遍完整流水线并打印事件流")
    ap.add_argument("pdf", nargs="+", help="要处理的 PDF(可以给多份)")
    ap.add_argument("--outdir", default=None,
                    help="产物目录, 默认 <第一份 PDF 所在目录>/ocr-selftest")
    ap.add_argument("--pages", default=None, metavar="N|A-B", help="只跑这些页")
    ap.add_argument("--dpi", type=float, default=300.0)
    ap.add_argument("--max-dpi", type=float, default=None)
    ap.add_argument("--engine", default="both",
                    choices=("both", "vision", "rapidocr"))
    ap.add_argument("--jobs", type=int, default=None)
    ap.add_argument("--force", action="store_true", help="覆盖已有产物")
    ap.add_argument("--resume", action="store_true")
    ap.add_argument("--glossary", default=None)
    ap.add_argument("--json", action="store_true",
                    help="事件流逐行输出 JSON(给脚本解析), 默认是人看的格式")
    ap.add_argument("--cancel-after", type=float, default=None, metavar="SEC",
                    help="跑到这么多秒就请求取消 —— 验证取消路径和页图清理")
    a = ap.parse_args(argv)

    pdfs = [Path(p).expanduser().resolve() for p in a.pdf]
    missing = [p for p in pdfs if not p.is_file()]
    if missing:
        print("找不到: " + ", ".join(str(p) for p in missing), file=sys.stderr)
        return 2
    outdir = (Path(a.outdir).expanduser() if a.outdir
              else pdfs[0].parent / "ocr-selftest")

    print("── 自检环境 ──")
    print(f"  {describe()}")
    print(f"  python   {sys.version.split()[0]}  frozen={bool(getattr(sys, 'frozen', False))}")
    #  打包验收要的自依赖证据: 这两行必须指向 .app 内部, 不能指向任何 .venv
    print(f"  prefix   {sys.prefix}")
    print(f"  exe      {sys.executable}")
    print(f"  src      {resource_path('src')}")
    print(f"  vision   {vision_bin()}  {'ok' if vision_bin().exists() else '缺失'}")
    print(f"  输出     {outdir}")
    print(f"  待处理   {len(pdfs)} 份: " + ", ".join(p.name for p in pdfs))

    t0 = time.time()
    seen: dict[str, int] = {}
    cancel = {"on": False}

    def should_cancel() -> bool:
        if a.cancel_after and not cancel["on"] and time.time() - t0 >= a.cancel_after:
            cancel["on"] = True
            print(f"[{time.time() - t0:7.1f}s] >>> 请求取消 <<<", flush=True)
        return cancel["on"]

    def on_event(ev: dict) -> None:
        t = ev.get("type")
        seen[t] = seen.get(t, 0) + 1
        if a.json:
            print(json.dumps(ev, ensure_ascii=False, default=str), flush=True)
            return
        el = f"[{time.time() - t0:7.1f}s]"
        if t == "progress":
            #  逐页事件几百条, 人看的模式下按 10% 抽样, 但计数是全的
            d, n = ev.get("done", 0), ev.get("total", 0)
            if n and (d == n or d % max(1, n // 10) == 0):
                print(f"{el} progress   {ev.get('engine')} {d}/{n}", flush=True)
        elif t == "stage":
            print(f"{el} stage      [{ev.get('step')}/{ev.get('steps')}] "
                  f"{ev.get('label')}", flush=True)
        elif t == "file_start":
            print(f"{el} file_start {ev.get('index')}/{ev.get('total')} "
                  f"{ev.get('name')}", flush=True)
        elif t == "pages":
            print(f"{el} pages      {ev.get('pages')} 页 "
                  f"repaired={ev.get('repaired')}", flush=True)
        elif t == "file_done":
            rec = ev.get("record") or {}
            print(f"{el} file_done  {ev.get('status')}  {rec.get('stem')}  "
                  f"{rec.get('seconds', 0):.1f}s  "
                  f"lines={rec.get('lines')} retrieval={rec.get('retrieval')}",
                  flush=True)
            for d in rec.get("degraded") or ():
                print(f"{el}            ⚠ {d}", flush=True)
            if rec.get("error"):
                print(f"{el}            ✗ {rec['error']}", flush=True)
        elif t == "batch_start":
            print(f"{el} batch_start {ev.get('total')} 份", flush=True)
        elif t == "batch_done":
            print(f"{el} batch_done  {ev.get('ok')} 成功 / {ev.get('degraded')} 降级 "
                  f"/ {ev.get('skipped')} 跳过 / {ev.get('failed')} 失败 "
                  f"/ cancelled={ev.get('cancelled')}  exit={ev.get('exit_code')}",
                  flush=True)

    job = pipeline.Job(
        files=pdfs, outdir=outdir, dpi=a.dpi, max_dpi=a.max_dpi,
        engine=a.engine, jobs=a.jobs, pages=a.pages,
        force=a.force, resume=a.resume,
        glossary=Path(a.glossary).expanduser() if a.glossary else None,
    )

    if a.cancel_after:
        #  取消要走和界面一样的那条路: 工作线程 + Runner.cancel()
        runner = pipeline.Runner(job)
        runner.start()
        summary: dict = {}
        while runner.is_alive() or not runner.events.empty():
            try:
                ev = runner.events.get(timeout=0.1)
            except Exception:                 # queue.Empty
                should_cancel()
                continue
            if ev.get("type") == "log":
                print("    | " + ev.get("line", ""), flush=True)
                continue
            if ev.get("type") == "crash":
                print("CRASH:\n" + ev.get("traceback", ""), file=sys.stderr)
                return 1
            if ev.get("type") == "batch_done":
                summary = ev
            on_event(ev)
            if should_cancel():
                runner.cancel()
        runner.join(5.0)
    else:
        summary = pipeline.run_sync(job, on_event)

    print("── 事件计数 ──")
    for k in sorted(seen):
        print(f"  {k:12s} {seen[k]}")
    print(f"── 用时 {time.time() - t0:.1f}s   退出码 {summary.get('exit_code')} ──")

    for rec in summary.get("records", []):
        for k in ("md", "searchable", "report"):
            p = rec.get(k)
            if p and Path(p).exists():
                print(f"  {k:10s} {Path(p).stat().st_size:>10,} B  {p}")
    return int(summary.get("exit_code", 0))


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)

    from .paths import bootstrap, patch_engine_paths
    bootstrap()

    if argv and argv[0] == "--selftest":
        return _selftest(argv[1:])
    if argv and argv[0] == "--cli":
        #  打包后也能用命令行跑书籍线(包里没有 python 可调, 只能从这里转进去)
        import run_books
        patch_engine_paths()
        rest = argv[1:]
        if rest and rest[0] == "--":
            rest = rest[1:]
        return run_books.main(rest)
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    #  macOS 双击 .app 时 LaunchServices 会塞一个 -psn_… 参数进来, 忽略掉
    from . import gui
    return gui.run()


if __name__ == "__main__":
    raise SystemExit(main())
