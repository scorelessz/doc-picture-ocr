#!/usr/bin/env python3
"""整本 book --vlm 汇总: 耗时、内存、翻转、独有片段、降级, 用 v2 真值抽查页比开不开 VLM 的 CER。只出数字。

输入 work/bench/p5/full/{en,zh}-{base,vlm}。结果写 bench/results/p5-full.json。
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))

from p3_fuse_parity import cer                   # noqa: E402

BOOKS = {"en": ("City of Broken Promises", "work/bench/spot-en2", [3]), "zh": ("失约之城", "work/bench/spot-zh", [])}


def main() -> int:
    F = ROOT / "work/bench/p5/full"
    out = {"phase": "p5", "name": "vlm-full-book", "note": "真值候选含这个 VLM, 绝对值偏乐观, 看相对差"}
    for tag, (stem, spot, ex) in BOOKS.items():
        truth = {int(k): v for k, v in json.loads((ROOT / spot / "truth.json").read_text("utf-8")).items()}
        pages = sorted(p for p in truth if p not in ex)
        rb, rv = (json.loads((F / f"{tag}-{k}.json").read_text("utf-8")) for k in ("base", "vlm"))
        fb, fv = (json.loads((F / f"{tag}-{k}/w/{stem}.fused.json").read_text("utf-8")) for k in ("base", "vlm"))
        ev = [json.loads(x) for x in (F / f"{tag}-vlm.log").read_text("utf-8").splitlines()]
        ev = ev[max(i for i, x in enumerate(ev) if x["event"] == "start"):]    # 日志是追加写的, 只看最后一次运行
        v = next(x for x in ev if x["event"] == "vlm")
        vp = [x for x in ev if x["event"] == "vlm_page"]
        ca, cb = cer(fb, truth, pages), cer(fv, truth, pages)
        out[tag] = {
            "pages": rv["pages"], "base_seconds": rb["total_seconds"], "base_sec_per_page": rb["sec_per_page"], "base_peak_mb": rb["peak_rss_self_mb"],
            "vlm_total_seconds": rv["total_seconds"], "vlm_sec_per_page": rv["sec_per_page"], "vlm_peak_mb": rv["peak_rss_self_mb"],
            "vlm_stage_seconds": rv["seconds"]["vlm"], "vlm_called": v["called"], "skipped_no_divergence": v["skipped_no_divergence"],
            "skipped_no_ink": v["skipped_no_ink"], "flips": v["flips"], "orphans": v["orphans"], "degraded": rv["degraded"],
            "truncated": sum(x["truncated"] for x in vp), "loop_cut": sum(x["loop_cut"] for x in vp),
            "truth_pages": len(pages), "cer_base": ca["cer"], "cer_vlm": cb["cer"], "edits_base": ca["edits"], "edits_vlm": cb["edits"]}
        print(tag, out[tag])
    (ROOT / "bench/results/p5-full.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
