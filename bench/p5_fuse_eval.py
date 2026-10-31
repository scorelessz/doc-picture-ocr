#!/usr/bin/env python3
"""Phase 5 融合评估: 双引擎融合 vs 加 VLM 第三票, 用 P1 v2 真值算 CER。只出数字。

VLM 文本用 P1 的 mlx-vlm 输出(work/bench/vlm-text), 融合输入是 Core ML 全链路的 fused.json。
用法: .venv/bin/python bench/p5_fuse_eval.py [--e2e e2e-coreml]
结果写 bench/results/p5-fuse.json。真值含 VLM 候选, 而且基底来自另一个模型, 所以结果偏乐观, 看相对差。
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))

from p3_fuse_parity import cer                   # noqa: E402

CLI = ROOT / ".build" / "release" / "ocr-cli"
BOOKS = {"en": ("City of Broken Promises", "work/bench/spot-en2", [3], "paddlevl16-mlx-spot-page"),
         "zh": ("失约之城", "work/bench/spot-zh", [], "paddlevl16-mlx-zh-spot-page")}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--e2e", default="e2e-coreml")
    a = ap.parse_args()
    out = {"phase": "p5", "name": "vlm-fuse", "vlm": "paddleocr-vl-1.6 8bit, mlx-vlm(P1 输出)", "e2e": a.e2e}
    w = ROOT / "work" / "bench"
    (w / "p5").mkdir(exist_ok=True)
    for tag, (stem, spot, ex, vt) in BOOKS.items():
        fp = w / a.e2e / tag / "work" / f"{stem}.fused.json"
        o, rp = w / "p5" / f"{tag}.fused.vlm.json", w / "p5" / f"{tag}.vlm-report.json"
        r = subprocess.run([str(CLI), "vlm-fuse", str(fp), "--vlm-dir", str(w / "vlm-text" / vt), "--out", str(o), "--report", str(rp)],
                           capture_output=True, text=True)
        if r.returncode:
            raise SystemExit(r.stderr[-300:])
        truth = {int(k): v for k, v in json.loads((ROOT / spot / "truth.json").read_text("utf-8")).items()}
        pages = sorted(p for p in truth if p not in ex)
        base, vlm = json.loads(fp.read_text("utf-8")), json.loads(o.read_text("utf-8"))
        ra, rb = cer(base, truth, pages), cer(vlm, truth, pages)
        rep = json.loads(rp.read_text("utf-8"))
        out[tag] = {"pages": pages, "two_engine": ra, "with_vlm": rb, "delta_pct_points": round((rb["cer"] - ra["cer"]) * 100, 3),
                    "report": {"pages": len(rep), "flips": sum(x["flips"] for x in rep), "orphans": sum(x["orphans"] for x in rep),
                               "orphan_chars": sum(x["orphan_chars"] for x in rep), "truncated": sum(x["truncated"] for x in rep),
                               "loop_cut": sum(x["loop_cut"] for x in rep), "skipped_no_ink": sum(x["skipped_no_ink"] for x in rep)}}
        print(tag, {k: ra[k] for k in ("edits", "cer", "ins", "del", "sub")}, "->", {k: rb[k] for k in ("edits", "cer", "ins", "del", "sub")}, out[tag]["report"])
        print(" by page", {p: (ra["edits_by_page"][p], rb["edits_by_page"][p]) for p in pages if ra["edits_by_page"][p] != rb["edits_by_page"][p]})
    (ROOT / "bench" / "results" / "p5-fuse.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
