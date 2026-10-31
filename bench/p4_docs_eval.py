#!/usr/bin/env python3
"""RecognizeDocumentsRequest 调研打分: 段落数、页码是否单独成段、与 BookLayout 删除的页码是否同一处、对 v2 真值的 CER。只出数字。

输入 work/bench/p4/docs/docs.json(bench/diag_documents.swift 产出)。结果写 bench/results/p4-documents.json。
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))
sys.path.insert(0, str(ROOT / "src"))

from rapidfuzz.distance import Levenshtein       # noqa: E402

import book_md                                   # noqa: E402
from p3_fuse_parity import norm_text             # noqa: E402

BOOKS = {"en": ("City of Broken Promises", "work/bench/spot-en2"), "zh": ("失约之城", "work/bench/spot-zh")}
NUM = re.compile(r"^[\s\-—–·.。、()（）]*\d{1,4}[\s\-—–·.。、()（）]*$")


def our_paragraphs(md: str) -> dict[int, int]:
    """md 里每页开始的段落数(续段落算 1): 按 <!-- page N --> 切。"""
    out, cur, starts = {}, None, 0
    for b in md.split("\n\n"):
        m = re.fullmatch(r"<!-- page (\d+) -->", b.strip())
        if m:
            cur = int(m.group(1))
            out[cur] = 0
            continue
        inline = re.search(r"<!-- page (\d+) -->", b)
        if inline:
            cur = int(inline.group(1))
            out[cur] = 1
            continue
        if cur is not None and b.strip():
            out[cur] += 1
    return out


def main() -> int:
    docs = json.loads((ROOT / "work/bench/p4/docs/docs.json").read_text("utf-8"))
    res = {"phase": "p4", "name": "recognize-documents", "pages": []}
    cache = {}
    for r in docs:
        tag, pno = re.search(r"(en|zh)-p(\d+)\.png", r["png"]).groups()
        pno = int(pno)
        stem, spot = BOOKS[tag]
        if tag not in cache:
            fused = json.loads((ROOT / "work/bench/p3" / f"{tag}-new.fused.json").read_text("utf-8"))
            o = book_md.Options()
            md = book_md.to_markdown(fused, o)
            truth = json.loads((ROOT / spot / "truth.json").read_text("utf-8"))
            vis = {p["page"]: p for p in json.loads((ROOT / f"work/bench/{stem}.vision.json").read_text("utf-8"))["pages"]}
            cache[tag] = (o.stats, our_paragraphs(md), truth, vis)
        st, ours, truth, vis = cache[tag]
        paras = r.get("paragraphs", [])
        dropped = [d for d in st["dropped_lines"] if d["page"] == pno and "页码" in d["reason"]]
        pj = vis[pno]
        num_paras = [p for p in paras if NUM.match(p["text"])]
        # 与我们删掉的页码是否同一处: 文本相同且框中心距 < 2 行高
        same = 0
        for d in dropped:
            cx, cy = (d["x"] + d["w"] / 2) / pj["width"], (d["y"] + d["h"] / 2) / pj["height"]
            for p in num_paras:
                x, y, w, h = p["box"]
                if abs(x + w / 2 - cx) < 0.05 and abs(1 - (y + h / 2) - cy) < 0.05:
                    same += 1
                    break
        t = truth[str(pno)]
        hyp = norm_text(r.get("transcript") or "")
        ops = Levenshtein.editops(t, hyp)
        c = {"insert": 0, "delete": 0, "replace": 0}
        for o in ops:
            c[o.tag] += 1
        res["pages"].append({"book": tag, "page": pno, "seconds": round(r["seconds"], 2),
                             "doc_paragraphs": len(paras), "our_paragraphs": ours.get(pno),
                             "doc_has_title": bool(r.get("title")), "tables": r.get("tables"), "lists": r.get("lists"),
                             "para_lines": [p["lines"] for p in paras],
                             "our_dropped_pagenums": len(dropped), "doc_numeric_paragraphs": len(num_paras), "same_place": same,
                             "pagenum_inside_transcript_end": bool(dropped) and any(d["text"].strip() in p["text"] and not NUM.match(p["text"]) for d in dropped for p in paras),
                             "truth_chars": len(t), "cer": round(len(ops) / max(1, len(t)), 5), "edits": len(ops), **c})
    for tag in BOOKS:
        v = [p for p in res["pages"] if p["book"] == tag]
        res[tag] = {"cer": round(sum(p["edits"] for p in v) / max(1, sum(p["truth_chars"] for p in v)), 5),
                    "chars": sum(p["truth_chars"] for p in v)}
    (ROOT / "bench/results/p4-documents.json").write_text(json.dumps(res, ensure_ascii=False, indent=1) + "\n", "utf-8")
    for p in res["pages"]:
        print({k: p[k] for k in ("book", "page", "seconds", "doc_paragraphs", "our_paragraphs", "our_dropped_pagenums", "doc_numeric_paragraphs", "same_place", "pagenum_inside_transcript_end", "cer", "insert", "delete", "replace")})
    print(res["en"], res["zh"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
