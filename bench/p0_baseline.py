#!/usr/bin/env python3
"""Phase 0 基准: 用现行 Python 书籍线跑一份 PDF, 只记**数字**写进 bench/baseline.json。

识别出的正文一个字都不进结果文件 —— 结果要提交进仓库、给云端会话看, 书的内容不能跟着走。

真值: 源 PDF 若自带原生文字层(电子版导出的 PDF), 就拿它当逐页真值:
  强制当扫描页重新识别(--force-ocr), 再把融合结果与原生文字逐页比 CER。
  没有原生文字层(纯扫描件)时, 只记一致性指标(分歧率/单源率/取回率等), CER 记 null。

用法:
  .venv/bin/python bench/p0_baseline.py <pdf> [--pages N|A-B] [--out bench/baseline.json]
  加 --reuse: 不重跑 OCR, 直接用 work/bench/ 里上次的 fused.json 重算指标(perf 记 null)。
产物(中间文件和 md/pdf)落在 work/bench/, 已被 .gitignore 挡住。
"""
from __future__ import annotations

import argparse
import json
import platform
import resource
import subprocess
import sys
import time
import unicodedata
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

import pymupdf                                   # noqa: E402

import book_md                                   # noqa: E402
import run_books                                 # noqa: E402

try:
    from rapidfuzz.distance import Levenshtein as _lev
    def distance(a: str, b: str) -> int:
        return _lev.distance(a, b)
except ImportError:                              # 慢但正确的兜底
    def distance(a: str, b: str) -> int:
        if len(a) < len(b):
            a, b = b, a
        prev = list(range(len(b) + 1))
        for i, ca in enumerate(a, 1):
            cur = [i]
            for j, cb in enumerate(b, 1):
                cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
            prev = cur
        return prev[-1]

#  native_text 判定沿用 book_render 的口径: 每页 ≥50 字才算有文字层
MIN_NATIVE_CHARS = 50


def canon(s: str) -> str:
    """比 CER 前的归一化: NFKC + 去掉所有空白(断行/空格不同不算错)。"""
    return "".join(unicodedata.normalize("NFKC", s).split())


def parse_pages(spec: str | None, n: int) -> list[int]:
    if not spec:
        return list(range(1, n + 1))
    if "-" in spec:
        a, b = spec.split("-", 1)
        return list(range(int(a), min(int(b), n) + 1))
    return list(range(1, min(int(spec), n) + 1))


def machine() -> dict:
    def sysctl(k: str) -> str | None:
        try:
            return subprocess.run(["sysctl", "-n", k], capture_output=True,
                                  text=True, timeout=5).stdout.strip() or None
        except (OSError, subprocess.SubprocessError):
            return None
    mem = sysctl("hw.memsize")
    return {"chip": sysctl("machdep.cpu.brand_string"),
            "ram_gb": round(int(mem) / 2**30, 1) if mem and mem.isdigit() else None,
            "macos": platform.mac_ver()[0] or None,
            "python": platform.python_version()}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--pages")
    ap.add_argument("--out", default=str(ROOT / "bench" / "baseline.json"))
    ap.add_argument("--reuse", action="store_true")
    a = ap.parse_args()

    pdf = Path(a.pdf).expanduser().resolve()
    doc = pymupdf.open(pdf)
    pages = parse_pages(a.pages, doc.page_count)
    native = {p: doc[p - 1].get_text("text") for p in pages}
    gt_pages = [p for p in pages if len(canon(native[p])) >= MIN_NATIVE_CHARS]
    has_gt = len(gt_pages) >= max(1, len(pages) // 2)

    work = ROOT / "work" / "bench"
    cfg = run_books.Config(input=pdf.parent, outdir=work / "output", workdir=work,
                           pages=a.pages, force=True, clobber=True,
                           force_ocr=has_gt)
    cfg.outdir.mkdir(parents=True, exist_ok=True)
    if a.reuse:
        seconds, rec = None, {"status": "reused"}
    else:
        t0 = time.time()
        res = run_books.run_batch(cfg, [pdf])
        seconds = time.time() - t0
        rec = (res.get("records") or [{}])[0]
        if rec.get("status") not in ("ok", "degraded"):
            print(f"运行失败: {rec.get('status')} {rec.get('error')}", file=sys.stderr)
            return 1

    fused = json.loads((work / f"{pdf.stem}.fused.json").read_text("utf-8"))
    st = fused["stats"]
    opts = book_md.Options()
    book_md.to_markdown(fused, opts)
    mdst = opts.stats

    cer = None
    if has_gt:
        fpages = {p["page"]: p for p in fused["pages"]}
        eng_lines = {}                             # 各引擎原始输出每页几行: 分清「没认出来」和「融合丢了」
        for e in ("vision", "rapidocr"):
            ep = work / f"{pdf.stem}.{e}.json"
            if ep.exists():
                eng_lines[e] = {p["page"]: len(p.get("lines", []))
                                for p in json.loads(ep.read_text("utf-8"))["pages"]}
        per = []                                   # (页, 编辑距离, 真值字数, 识别字数, 识别行数)
        for p in gt_pages:
            fp = fpages.get(p, {})
            ref = canon(native[p])
            hyp = canon("".join(l["text"] for l in fp.get("lines", [])))
            per.append((p, distance(ref, hyp), len(ref), len(hyp), len(fp.get("lines", []))))
        tot_d = sum(x[1] for x in per)
        tot_n = sum(x[2] for x in per)
        #  识别结果为空的页单独拎出来: 它们的 CER 恒为 1.0, 是「整页漏识别」而不是「读错字」,
        #  混在一起会把读字精度的数字整体拉坏, 也会把漏页问题藏进一个平均数里。
        empty = [x for x in per if x[3] == 0]
        rest = [x for x in per if x[3] > 0]
        worst = sorted(per, key=lambda x: -x[1] / max(1, x[2]))[:15]
        cer = {"pages": len(per), "chars": tot_n, "edits": tot_d,
               "cer": round(tot_d / max(1, tot_n), 5),
               "cer_excl_empty": round(sum(x[1] for x in rest) / max(1, sum(x[2] for x in rest)), 5),
               "empty_ocr_pages": [{"page": x[0], "ref_chars": x[2],
                                    **{f"{e}_lines": eng_lines.get(e, {}).get(x[0])
                                       for e in ("vision", "rapidocr")}}
                                   for x in empty],
               "worst_pages": [{"page": p, "cer": round(d / max(1, n), 4), "ref_chars": n,
                                "ocr_chars": h, "ocr_lines": nl,
                                "native_text": fpages.get(p, {}).get("native_text")}
                               for p, d, n, h, nl in worst]}

    ru_self = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    ru_kids = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    scale = 1 if sys.platform == "darwin" else 1024      # macOS 单位是字节, Linux 是 KB
    lines = max(1, st["lines"])
    out = {
        "phase": "p0",
        "pipeline": "python-books",
        "date": datetime.now().isoformat(timespec="seconds"),
        "machine": machine(),
        "source": {"file": pdf.name, "pages_total": doc.page_count,
                   "pages_run": len(pages), "native_text_pages": len(gt_pages),
                   "ground_truth": "native_text_layer" if has_gt else None},
        "accuracy": cer,
        "fusion": {"lines": st["lines"], "both": st["both"],
                   "divergent_rate": round(st["divergent"] / max(1, st["both"]), 4),
                   "single_source_rate": round(
                       (st["only_vision"] + st["only_rapidocr"]) / lines, 4),
                   "only_vision": st["only_vision"], "only_rapidocr": st["only_rapidocr"],
                   "dropped_empty": st["dropped_empty"],
                   "dropped_contained": st.get("dropped_contained", 0)},
        "markdown": {"paragraphs": mdst["paragraphs"], "headings": mdst["headings"],
                     "chars": mdst["chars"], "dropped": mdst["dropped"],
                     "dropped_detail": mdst["dropped_detail"],
                     "vertical_pages": len(mdst["vertical_pages"]),
                     "two_column_pages": len(mdst["two_column_pages"])},
        "searchable_pdf": {"retrieval": rec.get("retrieval")},
        "status": rec.get("status"),
        "degraded": rec.get("degraded"),
        "perf": None if seconds is None else {
                 "seconds": round(seconds, 1),
                 "sec_per_page": round(seconds / max(1, len(pages)), 3),
                 "peak_rss_mb": round(ru_self * scale / 2**20, 1),
                 "peak_rss_children_mb": round(ru_kids * scale / 2**20, 1)},
    }
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", "utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
