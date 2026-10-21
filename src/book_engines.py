#!/usr/bin/env python3
"""书籍线 · 第 2 步: 页图 -> 双引擎 OCR -> 每引擎一份契约 JSON。

和剧本线的 run_vision.py / run_rapidocr.py 并行存在, 不改动它们, 也刻意
不 import 它们 —— 书籍线和剧本线完全解耦, 一边改动不会波及另一边。
两条线的差别:
  - 页图来自 book_render.render_pdf(渲染), 不是 pdfimages(抽原图);
  - JSON 多了 dpi / pdf_width / pdf_height / zoom / rotation / native_text,
    嵌字模块靠这些把 OCR 框叠回原 PDF;
  - 原生文字页跳过 OCR, 直接用 PDF 自带的文字行(conf=1.0)。

输出(契约, 字段名固定):
  work/<名>.vision.json
  work/<名>.rapidocr.json
  {"source","engine","dpi","pages":[{"page","width","height","pdf_width",
    "pdf_height","zoom","rotation","image","native_text",
    "lines":[{"x","y","w","h","conf","text"}]}]}
  坐标: 像素, 原点左上, 像素 = 视觉 PDF 点 × zoom。
  顶层 dpi 是全书统一值; 逐页实际分辨率以该页的 zoom 为准(zoom × 72 = dpi),
  因为 book_render 会对内嵌图分辨率更高的页提升 dpi。

分批流水(2026-10 验收补)
  渲染不再是「整本先落盘再 OCR」: 每 --batch 页渲染 -> 两引擎识别 -> 立刻删页图,
  磁盘峰值与书的厚度无关(373 页真书实测 814 MB -> 一批 24 页约 52 MB)。
  开跑前按每页实际 dpi 打一行预估占用。异常/中断时 finally 清掉本次页图。
  页图目录是本模块自己选的(<work_dir>/<名>/pages)时允许覆盖已有页图,
  否则中断后的 --resume 必死在「拒绝覆盖」上。

用法:
  .venv/bin/python src/book_engines.py <pdf> [--dpi 300] [--max-dpi 600]
        [--pages A-B] [--batch 24] [--force-ocr]
        [--engine both|vision|rapidocr] [--jobs N] [--keep-pages] [--force]
退出码: 0 正常; 3 有页面识别失败(JSON 已写出, 失败页 lines 为空)。
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:          # 被别处 import 时也能找到 book_render
    sys.path.insert(0, _HERE)
from book_render import (                                   # noqa: E402
    DEFAULT_DPI, MAX_DPI, MAX_PIXELS, NATIVE_MIN_CHARS, PageInfo, ROOT,
    human_bytes, iter_pages, plan_render, relpath, render_pdf,
    sort_reading_order,
)

VISION_BIN = ROOT / "bin" / "vision-ocr"
ENGINES = ("vision", "rapidocr")
#  分批流水: 每 N 页「渲染 -> 两引擎 OCR -> 立刻删页图」。
#  磁盘峰值从整本(373 页真书实测约 814 MB)降到一批(24 页约 52 MB)。
#  0 = 不分批(整本先渲染完再 OCR, 旧行为)。
DEFAULT_BATCH = 24


def default_jobs() -> int:
    return max(1, min(4, (os.cpu_count() or 4) - 2))


# ---------------------------------------------------------------- Vision

def vision_page(png: Path) -> list[dict]:
    """调 bin/vision-ocr, 解析 TSV: x y w h conf text(像素, 原点左上)。"""
    r = subprocess.run([str(VISION_BIN), str(png)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"vision-ocr 退出码 {r.returncode}: "
                           f"{r.stderr.strip()[:200]}")
    lines = []
    for row in r.stdout.splitlines():
        c = row.split("\t")
        if len(c) != 6:
            continue
        try:
            x, y, w, h, conf = (float(v) for v in c[:5])
        except ValueError:
            continue
        if not c[5].strip():
            continue
        lines.append({"x": round(x, 1), "y": round(y, 1),
                      "w": round(w, 1), "h": round(h, 1),
                      "conf": round(conf, 4), "text": c[5]})
    return sort_reading_order(lines)


def run_vision(pages: list[PageInfo], jobs: int, verbose: bool = True,
               progress=None, *, offset: int = 0,
               total: int | None = None) -> tuple[dict[int, list[dict]], list[int]]:
    """Vision 走 subprocess, 线程池并发(GIL 不挡 subprocess)。

    progress: 可选 callable(已完成数, 总数, "Vision")。几百页的书不能静默,
    所以按完成顺序回调, 而不是按提交顺序。
    offset/total: 分批跑时给出**全书**的进度分母, 免得每批从 0 重数。
    """
    todo = [p for p in pages if not p.native_text and p.png]
    out: dict[int, list[dict]] = {}
    failed: list[int] = []
    if not todo:
        return out, failed
    grand = total if total is not None else len(todo)
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futs = {pool.submit(vision_page, p.png): p.index for p in todo}
        for n, fut in enumerate(as_completed(futs), 1):
            idx = futs[fut]
            try:
                out[idx] = fut.result()
            except Exception as e:                      # noqa: BLE001
                failed.append(idx)
                out[idx] = []
                print(f"  ⚠ 第{idx}页 Vision 失败: {e}", file=sys.stderr)
            if progress:
                progress(offset + n, grand, "Vision")
    if verbose:
        n = sum(len(v) for v in out.values())
        print(f"  Vision: {len(todo)} 页 {n} 行 "
              f"({time.time() - t0:.1f}s, {jobs} 并发)", file=sys.stderr)
    return out, failed


# ---------------------------------------------------------------- RapidOCR

def _rapid_normalize(result) -> list[dict]:
    """RapidOCR 3.x 返回对象(boxes/txts/scores); 老版本返回 [(box,text,score)]。"""
    boxes = txts = scores = None
    if hasattr(result, "boxes"):
        boxes, txts, scores = result.boxes, result.txts, result.scores
    elif isinstance(result, (list, tuple)) and result:
        first = result[0]
        if isinstance(first, (list, tuple)) and len(first) == 3:
            boxes = [r[0] for r in result]
            txts = [r[1] for r in result]
            scores = [r[2] for r in result]
        else:
            return _rapid_normalize(first)
    if boxes is None or txts is None:
        return []
    lines = []
    for box, txt, score in zip(boxes, txts, scores):
        xs = [float(p[0]) for p in box]
        ys = [float(p[1]) for p in box]
        if not str(txt).strip():
            continue
        lines.append({
            "x": round(min(xs), 1), "y": round(min(ys), 1),
            "w": round(max(xs) - min(xs), 1), "h": round(max(ys) - min(ys), 1),
            "conf": round(float(score), 4), "text": str(txt),
        })
    return sort_reading_order(lines)


_RAPID_ENGINE = None


def rapid_engine(verbose: bool = True):
    """RapidOCR 实例按进程复用: 分批跑和一次跑多本书都不该重复加载模型。"""
    global _RAPID_ENGINE
    if _RAPID_ENGINE is None:
        from rapidocr import RapidOCR                      # 延迟导入
        t0 = time.time()
        _RAPID_ENGINE = RapidOCR()
        if verbose:
            print(f"  RapidOCR 就绪 ({time.time() - t0:.1f}s)", file=sys.stderr)
    return _RAPID_ENGINE


def run_rapidocr(pages: list[PageInfo], verbose: bool = True,
                 progress=None, *, offset: int = 0, total: int | None = None,
                 engine=None) -> tuple[dict[int, list[dict]], list[int]]:
    """单实例复用, 顺序跑(ONNX 自己已经吃满多核, 再并发只会互相抢)。"""
    todo = [p for p in pages if not p.native_text and p.png]
    out: dict[int, list[dict]] = {}
    failed: list[int] = []
    if not todo:
        return out, failed
    grand = total if total is not None else len(todo)
    engine = engine or rapid_engine(verbose)
    t0 = time.time()
    for n, p in enumerate(todo, 1):
        try:
            out[p.index] = _rapid_normalize(engine(str(p.png)))
        except Exception as e:                              # noqa: BLE001
            failed.append(p.index)
            out[p.index] = []
            print(f"  ⚠ 第{p.index}页 RapidOCR 失败: {e}", file=sys.stderr)
        if progress:
            progress(offset + n, grand, "RapidOCR")
    if verbose:
        n = sum(len(v) for v in out.values())
        print(f"  RapidOCR: {len(todo)} 页 {n} 行 ({time.time() - t0:.1f}s)",
              file=sys.stderr)
    return out, failed


# ---------------------------------------------------------------- 组装

def build_doc(pdf: Path, engine: str, pages: list[PageInfo],
              lines_by_page: dict[int, list[dict]], base_dpi: float,
              root: Path = ROOT) -> dict:
    dpis = {p.dpi for p in pages}
    doc = {
        "source": relpath(pdf, root),
        "engine": engine,
        "dpi": (dpis.pop() if len(dpis) == 1 else base_dpi),
        "pages": [],
    }
    for p in pages:
        page = p.page_header(root)
        #  原生文字页: 两个引擎都填同一份原生行, 融合时自然算 both
        page["lines"] = p.native_lines if p.native_text \
            else lines_by_page.get(p.index, [])
        doc["pages"].append(page)
    return doc


def write_doc(doc: dict, out: Path, force: bool) -> None:
    if out.exists() and not force:
        raise SystemExit(f"{out} 已存在, 拒绝覆盖(确认后加 --force)")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=1),
                   encoding="utf-8")


@dataclass
class OcrResult:
    outputs: dict[str, Path]    # {engine: json 路径}
    pages: list[PageInfo]
    failed: list[int]           # 识别失败的页号
    #  原生文字层可疑、建议 --force-ocr 重认的页号(见 book_render.native_quality)
    native_suspect: list[int] = field(default_factory=list)


def _cleanup_pages(pngs, verbose: bool) -> int:
    """只删本次渲染出来的页图, 不碰目录里别的文件。"""
    gone = 0
    for p in pngs:
        try:
            if p and p.exists():
                p.unlink()
                gone += 1
        except OSError as e:                                # noqa: PERF203
            print(f"  ⚠ 删页图失败 {p}: {e}", file=sys.stderr)
    return gone


class _TermToInterrupt:
    """让 kill -TERM 也能走到 finally 的清理(默认 SIGTERM 直接杀进程)。

    几百页的书中途被 kill, 留下的几百 MB 孤儿页图既占盘又会挡住下次 --resume。
    只在本次调用期间接管 SIGTERM, 退出时原样还回去; 不在主线程就什么都不做。
    """

    def __enter__(self):
        self._old = None
        try:
            import signal
            self._signal = signal
            self._old = signal.getsignal(signal.SIGTERM)
            signal.signal(signal.SIGTERM, self._raise)
        except (ValueError, OSError, AttributeError):
            self._old = None                 # 非主线程 / 不支持, 放弃接管
        return self

    @staticmethod
    def _raise(signum, frame):
        raise KeyboardInterrupt("收到 SIGTERM, 正在清理页图")

    def __exit__(self, *exc):
        if self._old is not None:
            try:
                self._signal.signal(self._signal.SIGTERM, self._old)
            except (ValueError, OSError):
                pass
        return False


def _prune_dirs(pdir: Path, stem: str) -> None:
    """顺手收掉自己建的空目录。rmdir 只在目录确实空了才成功, 里面还有
    别的东西(用户的文件、别的 fork 的产物)就原样留着。"""
    cand = [pdir]
    if pdir.name == "pages" and pdir.parent.name == stem:
        cand.append(pdir.parent)            # work/<名>/ 也是本模块建的
    for d in cand:
        try:
            d.rmdir()
        except OSError:
            break


def ocr_pdf(pdf: str | Path, dpi: float = DEFAULT_DPI, engine: str = "both",
            jobs: int | None = None, keep_pages: bool = False,
            work_dir: Path | None = None, force: bool = False,
            root: Path = ROOT, verbose: bool = True, progress=None,
            *, max_dpi: float = MAX_DPI, pages: str | None = None,
            force_ocr: bool = False, batch: int = DEFAULT_BATCH,
            overwrite_pages: bool | None = None,
            **render_kw) -> OcrResult:
    """渲染 + OCR + 写 JSON。

    按 `batch` 页一批流水: 渲染一批 -> 两个引擎识别这一批 -> 立刻删掉这批页图。
    磁盘峰值因此与书的厚度无关(373 页真书: 整本 814 MB -> 一批约 52 MB)。
    batch=0 退回旧行为(整本先渲染完再 OCR)。

    显式转进来的渲染开关(驱动要用的):
      max_dpi   —— 分辨率上限, 封顶内嵌图原生 dpi 的上调;
      pages     —— "N" 或 "A-B", 先跑前几页试水;
      force_ocr —— 无视原生文字层, 一律重新识别。
    overwrite_pages: 允许覆盖已存在的页图; None = 页图目录是本模块自己选的
      (<work_dir>/<名>/pages)时自动允许 —— 否则中断/--keep-pages 之后
      --resume 必定死在「拒绝覆盖」上。显式 outdir 则保持覆盖保护。
      注意 force=True 比它**宽**: force 同时解除 JSON(work/<名>.*.json)的覆盖
      保护。驱动只是想让残留页图别挡住 --resume 的话, 传 overwrite_pages=True
      就够了(默认情形下本来就已经是 True), 不必动 force。
    异常或中断时, 本次渲染出来的页图在 finally 里清掉(--keep-pages 除外)。
    """
    pdf = Path(pdf).expanduser().resolve()
    if not pdf.exists():
        raise SystemExit(f"文件不存在: {pdf}")
    want = list(ENGINES) if engine == "both" else [engine]
    wdir = Path(work_dir) if work_dir else root / "work"
    outs = {e: wdir / f"{pdf.stem}.{e}.json" for e in want}

    #  先查占用再干活, 免得渲染半天最后被拒
    for e, p in outs.items():
        if p.exists() and not force:
            raise SystemExit(f"{p} 已存在, 拒绝覆盖(确认后加 --force)")
    if "vision" in want and not VISION_BIN.exists():
        raise SystemExit(f"找不到 {VISION_BIN}\n"
                         f"编译: swiftc -O src/vision_ocr.swift -o bin/vision-ocr")

    #  页图必须跟着 work_dir 走。不跟: --work-dir 指到别处时页图仍然落在
    #  项目 work/<名>/pages, 测试跑一次就在别的 fork 的 work/ 里留下目录。
    owns_pagedir = render_kw.get("outdir") is None
    if owns_pagedir:
        render_kw["outdir"] = wdir / pdf.stem / "pages"
    if overwrite_pages is None:
        overwrite_pages = owns_pagedir
    gray = render_kw.get("gray", True)

    plan = plan_render(
        pdf, dpi=dpi, gray=gray, max_dpi=max_dpi,
        max_pixels=render_kw.get("max_pixels", MAX_PIXELS),
        native_min_chars=render_kw.get("native_min_chars", NATIVE_MIN_CHARS),
        force_ocr=force_ocr, use_native_dpi=render_kw.get("use_native_dpi", True),
        render_native=render_kw.get("render_native", True), pages=pages,
    )
    if not plan["pages"]:
        raise SystemExit("没有可处理的页面")
    step = max(1, int(batch)) if batch else plan["pages"]
    peak = plan["est_bytes_per_page"] * min(step, max(plan["rendered"], 1))
    if verbose:
        print(f"══ 渲染 + OCR {pdf.name} ══", file=sys.stderr)
        print(f"  共 {plan['pages']} 页 (原生文字页 {plan['native']}, 跳过 OCR), "
              f"@{plan['dpi_min']:g}~{plan['dpi_max']:g}dpi", file=sys.stderr)
        print(f"  预估页图: 累计约 {human_bytes(plan['est_bytes'])}; "
              + (f"每 {step} 页一批, 磁盘峰值约 {human_bytes(peak)}"
                 if not keep_pages else
                 f"--keep-pages: 全部保留, 需要约 {human_bytes(plan['est_bytes'])}")
              + "  (粗估, 按灰度 PNG 经验压缩率)", file=sys.stderr)
        if not keep_pages and plan["est_bytes"] > (2 << 30):
            print("  ⚠ 这本书很大。嫌慢/嫌占盘可以 --no-native-dpi 或 "
                  "--max-dpi 300, 也可以 --pages 1-20 先试水。", file=sys.stderr)

    all_pages: list[PageInfo] = []
    created: list[Path] = []            # 本次渲染出来的页图(用于兜底清理)
    failed: list[int] = []
    results: dict[str, dict[int, list[dict]]] = {e: {} for e in want}
    done = {e: 0 for e in want}
    n_batches = 0

    def flush(bucket: list[PageInfo]) -> None:
        """这一批: 两个引擎识别 -> 删掉本批页图。"""
        nonlocal n_batches
        if not bucket:
            return
        n_batches += 1
        todo = [p for p in bucket if not p.native_text and p.png]
        if verbose and step < plan["pages"]:
            print(f"── 第 {n_batches} 批: 第{bucket[0].index}~{bucket[-1].index}页"
                  f" (需识别 {len(todo)} 页) ──", file=sys.stderr)
        if todo:
            if "vision" in want:
                part, f = run_vision(bucket, jobs or default_jobs(), verbose,
                                     progress, offset=done["vision"],
                                     total=plan["to_ocr"])
                results["vision"].update(part)
                done["vision"] += len(todo)
                failed.extend(f)
            if "rapidocr" in want:
                part, f = run_rapidocr(bucket, verbose, progress,
                                       offset=done["rapidocr"],
                                       total=plan["to_ocr"])
                results["rapidocr"].update(part)
                done["rapidocr"] += len(todo)
                failed.extend(f)
        if not keep_pages:
            batch_pngs = [p.png for p in bucket if p.png]
            gone = _cleanup_pages(batch_pngs, verbose)
            for p in batch_pngs:
                if p in created and not p.exists():
                    created.remove(p)
            if verbose and gone and step < plan["pages"]:
                print(f"   已清理 {gone} 张页图", file=sys.stderr)

    try:
        with _TermToInterrupt():
            bucket: list[PageInfo] = []
            for info in iter_pages(pdf, dpi=dpi, force=force, root=root,
                                   verbose=verbose, max_dpi=max_dpi, pages=pages,
                                   force_ocr=force_ocr,
                                   overwrite_pages=overwrite_pages, **render_kw):
                all_pages.append(info)
                if info.png:
                    created.append(info.png)
                bucket.append(info)
                if len(bucket) >= step:
                    flush(bucket)
                    bucket = []
            flush(bucket)

            if not all_pages:
                raise SystemExit("没有可处理的页面")

            for e in want:
                doc = build_doc(pdf, e, all_pages, results.get(e, {}), dpi, root)
                write_doc(doc, outs[e], force)
                if verbose:
                    n = sum(len(p["lines"]) for p in doc["pages"])
                    c = sum(len(l["text"]) for p in doc["pages"] for l in p["lines"])
                    print(f"-> {outs[e]}  {n} 行 {c} 字", file=sys.stderr)
    finally:
        #  异常 / Ctrl-C / kill 都会走到这里: 不留几百 MB 的孤儿页图。
        if not keep_pages:
            gone = _cleanup_pages([p for p in created if p.exists()], verbose)
            if verbose and gone:
                print(f"  已清理 {gone} 张页图(要保留下次加 --keep-pages)",
                      file=sys.stderr)
            if owns_pagedir:        # 只收自己建的目录, 不动用户指定的 --outdir
                _prune_dirs(Path(render_kw["outdir"]), pdf.stem)

    suspect = [p.index for p in all_pages if p.native_suspect]
    if suspect:
        print(f"⚠ {len(suspect)} 页的原生文字层可疑, 已原样当作识别结果: "
              f"{suspect[:20]}\n"
              f"  这些页跳过了双引擎识别。确认文字层不可用就加 --force-ocr 重跑。",
              file=sys.stderr)
    if failed:
        print(f"⚠ {len(failed)} 页识别失败: {sorted(set(failed))[:20]}",
              file=sys.stderr)
    return OcrResult(outputs=outs, pages=all_pages,
                     failed=sorted(set(failed)), native_suspect=suspect)


# ---------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="页图 -> Vision + RapidOCR -> 契约 JSON(书籍线第 2 步)")
    ap.add_argument("pdf")
    ap.add_argument("--dpi", type=float, default=DEFAULT_DPI)
    ap.add_argument("--max-dpi", type=float, default=MAX_DPI)
    ap.add_argument("--engine", choices=("both",) + ENGINES, default="both")
    ap.add_argument("--jobs", type=int, default=None,
                    help=f"Vision 并发数, 默认 {default_jobs()}")
    ap.add_argument("--keep-pages", action="store_true",
                    help="保留渲染出的页图(默认识别完就删)")
    ap.add_argument("--color", action="store_true", help="彩色渲染(默认灰度)")
    ap.add_argument("--pages", default=None, help="只处理 N 或 N-M")
    ap.add_argument("--outdir", default=None, help="页图目录, 默认 work/<名>/pages")
    ap.add_argument("--work-dir", default=None, help="JSON 目录, 默认 work/")
    ap.add_argument("--force-ocr", action="store_true",
                    help="无视原生文字层, 一律 OCR")
    ap.add_argument("--batch", type=int, default=DEFAULT_BATCH,
                    help=f"每 N 页一批(渲染->识别->删页图), 0=整本; 默认 {DEFAULT_BATCH}")
    ap.add_argument("--no-native-gate", action="store_true",
                    help="不检查原生文字层质量")
    ap.add_argument("--no-native-dpi", action="store_true",
                    help="不按内嵌图原生分辨率提升 dpi")
    ap.add_argument("--force", action="store_true", help="允许覆盖已存在的文件")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)

    t0 = time.time()
    try:
        res = _run(a)
    except KeyboardInterrupt:
        print("\n已中断(页图已清理)。重跑即可, 不必先删目录。", file=sys.stderr)
        return 130
    if not a.quiet:
        print(f"总耗时 {time.time() - t0:.1f}s", file=sys.stderr)
    return 3 if res.failed else 0


def _run(a) -> OcrResult:
    return ocr_pdf(a.pdf, dpi=a.dpi, engine=a.engine, jobs=a.jobs,
                   keep_pages=a.keep_pages, work_dir=a.work_dir, force=a.force,
                   verbose=not a.quiet,
                   outdir=a.outdir, gray=not a.color, pages=a.pages,
                   max_dpi=a.max_dpi, force_ocr=a.force_ocr, batch=a.batch,
                   native_gate=not a.no_native_gate,
                   use_native_dpi=not a.no_native_dpi)


if __name__ == "__main__":
    raise SystemExit(main())
