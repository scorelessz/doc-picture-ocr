#!/usr/bin/env python3
"""Phase 3 对拍: PDFKit 版 choose_dpi 与 P0 页图尺寸逐页比。只出数字。

用法: .venv/bin/python bench/p3_render_parity.py <pdf> --tag en|zh
读 work/bench/<名>.vision.json 里 P0 记下的 width/height/zoom。结果写 bench/results/p3-render-<tag>.json。
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / ".build" / "release" / "ocr-cli"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--tag", required=True)
    a = ap.parse_args()
    pdf = Path(a.pdf).expanduser()
    tmp = ROOT / "work" / "bench" / "p3"
    tmp.mkdir(parents=True, exist_ok=True)
    info = tmp / f"{a.tag}-page-info.json"
    r = subprocess.run([str(CLI), "page-info", str(pdf), "--out", str(info)], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"ocr-cli page-info 失败: {r.stderr.strip()[:300]}")
    sw = {int(p["page"]): p for p in json.loads(info.read_text("utf-8"))}
    py = {p["page"]: p for p in json.loads((ROOT / "work" / "bench" / f"{pdf.stem}.vision.json").read_text("utf-8"))["pages"]}
    bad = []
    for n, p in py.items():
        q = sw.get(n)
        if q is None or p["width"] != q["width"] or p["height"] != q["height"] or abs(p["zoom"] - q["zoom"]) > 1e-6:
            bad.append({"page": n, "py": [p["width"], p["height"], p["zoom"]],
                        "swift": None if q is None else [q["width"], q["height"], q["zoom"]]})
    out = {"phase": "p3", "source": pdf.name, "pages": len(py), "swift_pages": len(sw), "mismatch": len(bad),
           "dpi_values_swift": sorted({q["dpi"] for q in sw.values()}), "first_mismatches": bad[:20],
           "identical": not bad and len(py) == len(sw)}
    (ROOT / "bench" / "results" / f"p3-render-{a.tag}.json").write_text(
        json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print(json.dumps(out, ensure_ascii=False))
    return 0 if out["identical"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
