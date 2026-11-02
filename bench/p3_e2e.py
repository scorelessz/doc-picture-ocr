#!/usr/bin/env python3
"""Phase 3 端到端: 两本书整本跑 ocr-cli book, 与 P0 的 Python 数字和上一步 Swift 链路对比。只出数字。

用法: .venv/bin/python bench/p3_e2e.py [--only en|zh]
产物落 work/bench/e2e/<tag>/, 不进仓库。结果写 bench/results/p3-e2e.json。
md 对比的基线是 work/bench/p3/<tag>-chain.swift.md(P0 的 pymupdf 页图 + Swift 融合 + Swift md), 要先跑 bench/p3_chain.py。
"""
from __future__ import annotations

import argparse
import difflib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))

import pymupdf                                   # noqa: E402

CLI = ROOT / ".build" / "release" / "ocr-cli"
HOME = Path.home() / "Desktop" / "Ignore"
OUTDIR, EXTRA = "e2e", []
BOOKS = {"en": ("City of Broken Promises", ["--force-ocr"], "baseline.json"),
         "zh": ("失约之城", [], "baseline-zh.json")}


def md_compare(a: str, b: str) -> dict:
    x, y = a.split("\n\n"), b.split("\n\n")
    sm = difflib.SequenceMatcher(None, x, y, autojunk=False)
    same = sum(m.size for m in sm.get_matching_blocks())
    return {"identical": a == b, "blocks_a": len(x), "blocks_b": len(y), "blocks_equal": same,
            "block_equal_ratio": round(same / max(1, max(len(x), len(y))), 4),
            "chars_a": len(a), "chars_b": len(b)}


def run(tag: str) -> dict:
    stem, extra, base = BOOKS[tag]
    extra = extra + EXTRA
    w = ROOT / "work" / "bench" / OUTDIR / tag
    (w / "work").mkdir(parents=True, exist_ok=True)
    src = HOME / f"{stem}.pdf"
    res_f = w / "result.json"
    cmd = [str(CLI), "book", str(src), "--outdir", str(w / "out"), "--workdir", str(w / "work"),
           "--force", "--result", str(res_f)] + extra
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"{tag}: ocr-cli book 退出码 {r.returncode}: {r.stderr[-400:]}")
    res = json.loads(res_f.read_text("utf-8"))
    p0 = json.loads((ROOT / "bench" / base).read_text("utf-8"))
    md = (w / "out" / f"{stem}.md").read_text("utf-8")
    chain = ROOT / "work" / "bench" / "p3" / f"{tag}-chain.swift.md"
    out_pdf = w / "out" / f"{stem}.searchable.pdf"
    fused = json.loads((w / "work" / f"{stem}.fused.json").read_text("utf-8"))
    d = pymupdf.open(out_pdf)
    return {"source": stem, "pages": res["pages"], "degraded": res["degraded"],
            "swift": {k: res[k] for k in ("total_seconds", "sec_per_page", "peak_rss_self_mb", "peak_rss_children_mb", "seconds")},
            "python_p0": p0["perf"],
            "fusion_swift": fused["stats"], "fusion_p0": p0["fusion"],
            "gate_native_pages": [p["page"] for p in fused["pages"] if p.get("no_ink") and p.get("text_source") == "native_text"],
            "gate_blank_pages": [p["page"] for p in fused["pages"] if p.get("no_ink") and p.get("text_source") != "native_text"],
            "native_pages": [p["page"] for p in fused["pages"] if not p.get("no_ink") and p.get("text_source") == "native_text"],
            "md_vs_swift_chain": md_compare(chain.read_text("utf-8"), md) if chain.exists() else None,
            "source_prefix_identical": out_pdf.read_bytes()[:src.stat().st_size] == src.read_bytes(),
            "pdf_pages": d.page_count, "pdf_producer": d.metadata.get("producer"),
            "size_in": src.stat().st_size, "size_out": out_pdf.stat().st_size}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=sorted(BOOKS))
    ap.add_argument("--paddle", choices=("coreml", "python"), default="coreml")
    ap.add_argument("--result", default="p3-e2e.json")
    ap.add_argument("--workdir", default="e2e")
    a = ap.parse_args()
    global OUTDIR, EXTRA
    OUTDIR, EXTRA = a.workdir, ["--paddle", a.paddle]
    dst = ROOT / "bench" / "results" / a.result
    out = json.loads(dst.read_text("utf-8")) if dst.exists() else {"phase": "p3", "name": "e2e"}
    for tag in ([a.only] if a.only else BOOKS):
        out[tag] = run(tag)
        print(json.dumps(out[tag], ensure_ascii=False), flush=True)
    dst.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
