#!/usr/bin/env python3
"""Phase 2 门槛: 同一批页图, Swift 版 `ocr-cli vision` 与现有 bin/vision-ocr 的 TSV 逐行对拍。只出数字。

页图用现行流水线的渲染(pymupdf, choose_dpi), 两边吃同一张 PNG, 只比 Vision 部分。

用法: .venv/bin/python bench/p2_parity.py <pdf> [--pages 11,12,50] [--out bench/results/p2-parity.json]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import pymupdf                                   # noqa: E402

from book_render import choose_dpi              # noqa: E402
from p1_vlm import parse_pages                  # noqa: E402

OLD = ROOT / "bin" / "vision-ocr"
NEW = ROOT / ".build" / "release" / "ocr-cli"


def run(cmd: list[str]) -> list[str]:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"{cmd[0]} 退出码 {r.returncode}: {r.stderr.strip()[:200]}")
    return [l for l in r.stdout.splitlines() if l.strip()]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--pages", default="11,12,50,120,185")
    ap.add_argument("--out", default=str(ROOT / "bench" / "results" / "p2-parity.json"))
    a = ap.parse_args()

    pdf = Path(a.pdf).expanduser()
    doc = pymupdf.open(pdf)
    tmp = ROOT / "work" / "bench" / "p2"
    tmp.mkdir(parents=True, exist_ok=True)
    per = []
    for pno in parse_pages(a.pages, doc.page_count):
        page = doc[pno - 1]
        z = choose_dpi(page) / 72.0
        png = tmp / f"{pdf.stem}-p{pno:04d}.png"
        page.get_pixmap(matrix=pymupdf.Matrix(z, z), colorspace=pymupdf.csGRAY, alpha=False).save(str(png))
        old, new = run([str(OLD), str(png)]), run([str(NEW), "vision", str(png)])
        same = sum(1 for x, y in zip(old, new) if x == y)
        text_same = sum(1 for x, y in zip(old, new) if x.split("\t")[5:] == y.split("\t")[5:])
        per.append({"page": pno, "old_lines": len(old), "new_lines": len(new),
                    "identical_lines": same, "identical_text": text_same,
                    "identical": old == new})
        print(per[-1], flush=True)
    out = {"phase": "p2", "source": pdf.name, "pages": per,
           "all_identical": all(r["identical"] for r in per)}
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print("全部逐行一致" if out["all_identical"] else "有差异，见上")
    return 0 if out["all_identical"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
