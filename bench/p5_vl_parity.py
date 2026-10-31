#!/usr/bin/env python3
"""Phase 5 门槛: 进程内 PaddleOCR-VL(Swift + mlx-swift) 与 P1 的 mlx-vlm 文本比。只出数字。

页图渲染方式与 p1_vlm.py 相同(pymupdf 灰度 @ choose_dpi)。门槛: 字符一致率 ≥ 98%。
用法: .venv/bin/python bench/p5_vl_parity.py --model <dir> [--en 11,12] [--zh 15]
结果写 bench/results/p5-vl-parity.json。
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

import pymupdf                                   # noqa: E402
from rapidfuzz.distance import Levenshtein       # noqa: E402

from book_render import choose_dpi              # noqa: E402

CLI = ROOT / ".build" / "release" / "ocr-cli"
BOOKS = {"en": ("City of Broken Promises", "paddlevl16-mlx-spot-page", "3,8,9,11,12,50,120,185,236,300"),
         "zh": ("失约之城", "paddlevl16-mlx-zh-spot-page", "7,15,18,27,30,113,164,258,50,100,150,200,250,300,350")}


def fold(s: str) -> str:
    return "".join(s.split())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--en", default=BOOKS["en"][2])
    ap.add_argument("--zh", default=BOOKS["zh"][2])
    a = ap.parse_args()
    T = ROOT / "work/bench/p5/vl"
    T.mkdir(parents=True, exist_ok=True)
    items = []
    for tag, spec in (("en", a.en), ("zh", a.zh)):
        stem, vt, _ = BOOKS[tag]
        doc = pymupdf.open(Path.home() / "Desktop/Ignore" / f"{stem}.pdf")
        for p in map(int, filter(None, spec.split(","))):
            f = T / f"{tag}-p{p:04d}.png"
            if not f.exists():
                pg = doc[p - 1]
                z = choose_dpi(pg) / 72.0
                pg.get_pixmap(matrix=pymupdf.Matrix(z, z), colorspace=pymupdf.csGRAY, alpha=False).save(str(f))
            items.append((tag, p, f, ROOT / "work/bench/vlm-text" / vt / f"p{p:04d}.txt"))
    of = T / "swift.json"
    r = subprocess.run([str(CLI), "vl", *[str(i[2]) for i in items], "--vl-model", a.model, "--out", str(of)],
                       capture_output=True, text=True, cwd=ROOT)
    if r.returncode:
        raise SystemExit(r.stdout[-300:] + r.stderr[-600:])
    got = json.loads(of.read_text("utf-8"))
    pages, tot = [], {"en": [0, 0], "zh": [0, 0]}
    for tag, p, f, ref in items:
        x, y = fold(ref.read_text("utf-8")), fold(got[str(f)])
        d = Levenshtein.distance(x, y)
        tot[tag][0] += d
        tot[tag][1] += max(1, len(x))
        pages.append({"book": tag, "page": p, "ref_chars": len(x), "got_chars": len(y), "edits": d, "identical": x == y})
    m = re.search(r"加载 ([\d.]+)s\s+均值 ([\d.]+)s/页\s+峰值内存 (\d+) MB", r.stdout)
    out = {"phase": "p5", "name": "vl-parity", "criterion": "char_agreement >= 0.98",
           "char_agreement": {t: round(1 - v[0] / max(1, v[1]), 4) for t, v in tot.items() if v[1]},
           "pages_identical": sum(p["identical"] for p in pages), "pages": len(pages),
           "load_seconds": float(m[1]) if m else None, "sec_per_page": float(m[2]) if m else None,
           "peak_rss_mb": int(m[3]) if m else None, "per_page": pages}
    (ROOT / "bench/results/p5-vl-parity.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print({k: v for k, v in out.items() if k != "per_page"})
    print([(p["book"], p["page"], p["ref_chars"], p["got_chars"], p["edits"]) for p in pages])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
