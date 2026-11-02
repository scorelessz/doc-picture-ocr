#!/usr/bin/env python3
"""Phase 3 对拍: 同一份 Python fused.json 分别喂 src/book_md.py 与 ocr-cli md, md 全文、stats、丢弃明细逐项比。只出数字。

用法: .venv/bin/python bench/p3_md_parity.py <书名(不含 .pdf)> --tag en|zh
结果写 bench/results/p3-md-<tag>.json; 产物落 work/bench/p3/, 不进仓库。
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

import book_md                                   # noqa: E402

MD_MARK = "<!-- generated-by: book-line -->"     # 与 run_books.MD_MARK 相同(不 import, 免得拉上 Vision/RapidOCR 依赖)
CLI = ROOT / ".build" / "release" / "ocr-cli"
SCALARS = ("pages", "lines_in", "rows", "kept_rows", "paragraphs", "headings", "dropped", "divergent",
           "low_conf", "only_one_engine", "chars", "malformed_lines", "vertical_pages", "two_column_pages")


def one(fused_path: Path, fused: dict, tag: str, marks: bool) -> dict:
    tmp = ROOT / "work" / "bench" / "p3"
    tmp.mkdir(parents=True, exist_ok=True)
    name = f"{tag}-{'marks' if marks else 'nomarks'}"
    opts = book_md.Options(page_marks=marks)
    md = book_md.to_markdown(fused, opts)
    py_md = f"{MD_MARK}\n\n{md.lstrip(chr(10))}"
    (tmp / f"{name}.py.md").write_text(py_md, encoding="utf-8")

    sw_md, sw_st = tmp / f"{name}.swift.md", tmp / f"{name}.swift.stats.json"
    cmd = [str(CLI), "md", str(fused_path), "--out", str(sw_md), "--stats", str(sw_st), "--force"]
    if not marks:
        cmd.append("--no-page-marks")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"ocr-cli md 失败: {r.stderr.strip()[:300]}")
    sw = sw_md.read_text("utf-8")
    st = json.loads(sw_st.read_text("utf-8"))
    py = opts.stats

    res = {"py_chars": len(py_md), "swift_chars": len(sw), "md_identical": py_md == sw,
           "stats_mismatch": {k: [py[k], st[k]] for k in SCALARS if py[k] != st[k]},
           "dropped_detail_equal": py["dropped_detail"] == st["dropped_detail"],
           "dropped_lines_py": len(py["dropped_lines"]), "dropped_lines_swift": len(st["dropped_lines"]),
           "dropped_lines_equal": False, "dropped_detail": py["dropped_detail"]}
    bad = 0
    for a, b in zip(py["dropped_lines"], st["dropped_lines"]):
        if (a["page"], a["reason"], a["text"]) != (b["page"], b["reason"], b["text"]) \
                or max(abs(a[k] - b[k]) for k in "xywh") > 1e-6:
            bad += 1
    res["dropped_lines_diff"] = bad
    res["dropped_lines_equal"] = bad == 0 and len(py["dropped_lines"]) == len(st["dropped_lines"])
    if not res["md_identical"]:
        pa, pb = py_md.split("\n\n"), sw.split("\n\n")
        res["blocks_py"], res["blocks_swift"] = len(pa), len(pb)
        res["blocks_differ"] = sum(1 for x, y in zip(pa, pb) if x != y) + abs(len(pa) - len(pb))
        res["first_diff_block"] = next((i for i, (x, y) in enumerate(zip(pa, pb)) if x != y), min(len(pa), len(pb)))
    res["identical"] = (res["md_identical"] and not res["stats_mismatch"] and res["dropped_detail_equal"]
                        and res["dropped_lines_equal"])
    return res


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("stem")
    ap.add_argument("--tag", required=True)
    a = ap.parse_args()
    fp = ROOT / "work" / "bench" / f"{a.stem}.fused.json"
    fused = json.loads(fp.read_text("utf-8"))
    out = {"phase": "p3", "source": a.stem, "fused": "python legacy fused.json",
           "with_page_marks": one(fp, fused, a.tag, True), "no_page_marks": one(fp, fused, a.tag, False)}
    out["identical"] = out["with_page_marks"]["identical"] and out["no_page_marks"]["identical"]
    (ROOT / "bench" / "results" / f"p3-md-{a.tag}.json").write_text(
        json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0 if out["identical"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
