#!/usr/bin/env python3
"""Phase 1 对照组: P0 跑出的 Vision / RapidOCR / 融合结果在同一批页上的指标, 口径与 p1_vlm.py 一致。

不重跑 OCR, 只读 work/bench/<名>.{vision,rapidocr,fused}.json。只记数字。

用法:
  .venv/bin/python bench/p1_ctc.py <pdf> [--pages 3,8-12,20,62,98,160,324] [--out bench/results/p1-ctc.json]
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

import pymupdf                                   # noqa: E402
from rapidfuzz.distance import Levenshtein       # noqa: E402

from p1_vlm import canon, parse_pages           # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--pages", default="3,8-12,20,62,98,160,324")
    ap.add_argument("--out", default=str(ROOT / "bench" / "results" / "p1-ctc.json"))
    a = ap.parse_args()

    pdf = Path(a.pdf).expanduser().resolve()
    doc = pymupdf.open(pdf)
    pages = parse_pages(a.pages, doc.page_count)
    refs = {p: canon(doc[p - 1].get_text("text")) for p in pages}
    gt = [p for p in pages if len(refs[p]) >= 50]
    N = max(1, sum(len(refs[p]) for p in gt))

    res = {}
    for eng in ("vision", "rapidocr", "fused"):
        src = ROOT / "work" / "bench" / f"{pdf.stem}.{eng}.json"
        if not src.exists():
            continue
        by = {p["page"]: p for p in json.loads(src.read_text("utf-8"))["pages"]}
        cnt = {"insert": 0, "delete": 0, "replace": 0}
        empty, per = [], []
        for p in gt:
            hyp = canon("".join(l["text"] for l in by.get(p, {}).get("lines", [])))
            if not hyp:
                empty.append(p)
            pc = {"insert": 0, "delete": 0, "replace": 0}
            for op in Levenshtein.editops(refs[p], hyp):
                pc[op.tag] += 1
            for k in cnt:
                cnt[k] += pc[k]
            per.append({"page": p, "ref_chars": len(refs[p]), "hyp_chars": len(hyp),
                        "ins": pc["insert"], "del": pc["delete"], "sub": pc["replace"],
                        "requests": 0, "seconds": 0.0, "error": None})
        #  逐页明细另存一份, 口径与 p1_vlm 一致, 供 p1_summary 汇总
        dst = Path(a.out).with_name(f"p1-ctc-{eng}.json")
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(json.dumps({"phase": "p1", "name": f"ctc-{eng}", "per_page": per},
                                  ensure_ascii=False, indent=1) + "\n", "utf-8")
        res[eng] = {"cer": round(sum(cnt.values()) / N, 5),
                    "ins_rate": round(cnt["insert"] / N, 5),
                    "del_rate": round(cnt["delete"] / N, 5),
                    "sub_rate": round(cnt["replace"] / N, 5),
                    "empty_pages": empty}
    out = {"phase": "p1", "name": "ctc-baseline", "date": datetime.now().isoformat(timespec="seconds"),
           "source": pdf.name, "pages": gt, "ref_chars": N, "engines": res}
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
