#!/usr/bin/env python3
"""汇总 bench/results/p1-*.json: 正常页精度与「白页编造」分开算。

白页 = 渲染图里几乎没有墨迹的页(bench/diag-pdfkit.jsonl 里 dark_lt128 < 0.001)。
这些页的 PDF 文字层有字, 但图上没有, 拿文字层当真值会把「什么都没读出来」(正确)
算成全错、把「编了一页字」算成部分对。所以白页不进 CER, 只统计模型在白页上吐了多少字。

用法: python3 bench/p1_summary.py [--blank 10,20,...]
"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def blank_pages() -> set[int]:
    p = ROOT / "bench" / "diag-pdfkit.jsonl"
    rows = [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
    return {r["page"] for r in rows if r["dark_lt128"] < 0.001}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--blank")
    a = ap.parse_args()
    blank = {int(x) for x in a.blank.split(",")} if a.blank else blank_pages()
    print(f"白页: {sorted(blank)}\n")
    print(f"{'结果':<44} {'页':>3} {'CER':>7} {'插入':>7} {'删除':>7} {'替换':>7} {'白页吐字':>8} {'秒/页':>6}")
    for f in sorted((ROOT / "bench" / "results").glob("p1-*.json")):
        d = json.loads(f.read_text())
        per = d.get("per_page")
        if not per:
            continue
        ok = [r for r in per if r["page"] not in blank and r["ref_chars"] >= 50]
        n = max(1, sum(r["ref_chars"] for r in ok))
        s = lambda k: sum(r[k] for r in ok)                     # noqa: E731
        fab = sum(r["hyp_chars"] for r in per if r["page"] in blank)
        secs = [r["seconds"] for r in ok if r["requests"]]
        print(f"{f.stem:<44} {len(ok):>3} {(s('ins')+s('del')+s('sub'))/n:>7.4f} "
              f"{s('ins')/n:>7.4f} {s('del')/n:>7.4f} {s('sub')/n:>7.4f} {fab:>8} "
              f"{(sum(secs)/max(1,len(secs))):>6.1f}")


if __name__ == "__main__":
    main()
