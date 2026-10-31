#!/usr/bin/env python3
"""PDFKit 渲染整条链 vs pymupdf 页图 + 新融合: 用 P1 v2 真值算融合结果的 CER。只出数字。

要先跑 bench/p3_e2e.py 和 bench/p3_fuse_parity.py。结果写 bench/results/p3-render-cer.json。
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))

from p3_fuse_parity import cer                   # noqa: E402

E2E = "e2e"
BOOKS = {"en": ("City of Broken Promises", "work/bench/spot-en2", [3]), "zh": ("失约之城", "work/bench/spot-zh", [])}


def main() -> int:
    global E2E
    if len(sys.argv) > 1:
        E2E = sys.argv[1]
    out = {"phase": "p3", "name": "render-cer", "chain": E2E, "threshold_pct_points": 0.2}
    w = ROOT / "work" / "bench"
    for tag, (stem, spot, ex) in BOOKS.items():
        truth = {int(k): v for k, v in json.loads((ROOT / spot / "truth.json").read_text("utf-8")).items()}
        pages = sorted(p for p in truth if p not in ex)
        a = json.loads((w / "p3" / f"{tag}-new.fused.json").read_text("utf-8"))
        b = json.loads((w / E2E / tag / "work" / f"{stem}.fused.json").read_text("utf-8"))
        ra, rb = cer(a, truth, pages), cer(b, truth, pages)
        out[tag] = {"pages": pages, "excluded": ex, "pymupdf_new_fuse": ra, "pdfkit_chain": rb,
                    "delta_pct_points": round((rb["cer"] - ra["cer"]) * 100, 3)}
        print(tag, {k: ra[k] for k in ("chars", "edits", "cer", "ins", "del", "sub")},
              {k: rb[k] for k in ("edits", "cer", "ins", "del", "sub")}, out[tag]["delta_pct_points"])
        print(" by page", {p: (ra["edits_by_page"][p], rb["edits_by_page"][p]) for p in pages if ra["edits_by_page"][p] != rb["edits_by_page"][p]})
    (ROOT / "bench" / "results" / (sys.argv[2] if len(sys.argv) > 2 else "p3-render-cer.json")).write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
