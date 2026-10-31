#!/usr/bin/env python3
"""Claude 多模态抽查 · 计分: 以 Claude 看图转写为第二真值, 只输出数字。

输入(都在本机 work/ 下, 不提交):
  work/bench/spot/manifest.json, pNNNN.native.json      spot_prep.py 产出
  work/bench/spot/claude/pNNNN.txt                      Claude 逐条带看图的转写(白页写空文件)
  work/bench/spot/adjudication.json                     原生文字层 vs Claude 分歧的逐条裁决计数:
      {"3": {"diffs": 12, "native": 2, "claude": 9, "neither": 1, "unclear": 0}, ...}
  work/bench/<名>.{vision,rapidocr,fused}.json          P0 的 CTC 结果
  work/bench/vlm-text/<name>-<mode>/pNNNN.txt           p1_vlm.py --save-text 的 VLM 原文

输出 bench/results/p1-spotcheck.json(只有数字):
  - 原生文字层相对 Claude 转写的差异率(真值本身有多脏)
  - 每个引擎分别相对「原生文字层」和「Claude 转写」的 CER / 插入 / 删除 / 替换
  - 白页上各引擎(含 Claude)吐出的字数
  - 裁决计数汇总

用法: .venv/bin/python bench/spot_score.py <pdf>
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from rapidfuzz.distance import Levenshtein       # noqa: E402

from p1_vlm import canon                        # noqa: E402

SPOT = ROOT / "work" / "bench" / "spot"


def ops(ref: str, hyp: str) -> dict:
    c = {"ins": 0, "del": 0, "sub": 0}
    for op in Levenshtein.editops(ref, hyp):
        c[{"insert": "ins", "delete": "del", "replace": "sub"}[op.tag]] += 1
    return c


def rate(c: dict, n: int) -> dict:
    n = max(1, n)
    return {"cer": round((c["ins"] + c["del"] + c["sub"]) / n, 5),
            **{f"{k}_rate": round(v / n, 5) for k, v in c.items()}}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--out", default=str(ROOT / "bench" / "results" / "p1-spotcheck.json"))
    a = ap.parse_args()
    stem = Path(a.pdf).expanduser().stem

    manifest = {int(k): v for k, v in json.loads((SPOT / "manifest.json").read_text()).items()}
    claude = {}
    for p in manifest:
        f = SPOT / "claude" / f"p{p:04d}.txt"
        if f.exists():
            claude[p] = canon(f.read_text("utf-8"))
    native = {p: canon("".join(l["text"] for l in json.loads((SPOT / f"p{p:04d}.native.json").read_text())))
              for p in manifest}

    engines: dict[str, dict[int, str]] = {}
    for e in ("vision", "rapidocr", "fused"):
        f = ROOT / "work" / "bench" / f"{stem}.{e}.json"
        if f.exists():
            by = {pg["page"]: pg for pg in json.loads(f.read_text("utf-8"))["pages"]}
            engines[f"ctc-{e}"] = {p: canon("".join(l["text"] for l in by.get(p, {}).get("lines", [])))
                                   for p in manifest}
    for d in sorted((ROOT / "work" / "bench" / "vlm-text").glob("*")):
        texts = {p: canon((d / f"p{p:04d}.txt").read_text("utf-8"))
                 for p in manifest if (d / f"p{p:04d}.txt").exists()}
        if texts:
            engines[d.name] = texts

    text_pages = [p for p in manifest if not manifest[p]["blank"] and p in claude]
    blank_pages = [p for p in manifest if manifest[p]["blank"]]

    #  真值本身: 原生文字层 vs Claude
    gt = {"ins": 0, "del": 0, "sub": 0}
    gt_pages = {}
    for p in text_pages:
        c = ops(claude[p], native[p])
        gt_pages[p] = rate(c, len(claude[p]))
        for k in gt:
            gt[k] += c[k]
    n_claude = sum(len(claude[p]) for p in text_pages)
    n_native = sum(len(native[p]) for p in text_pages)

    res = {}
    for name, texts in engines.items():
        pages = [p for p in text_pages if p in texts]
        vs_c = {"ins": 0, "del": 0, "sub": 0}
        vs_n = {"ins": 0, "del": 0, "sub": 0}
        for p in pages:
            for k, v in ops(claude[p], texts[p]).items():
                vs_c[k] += v
            for k, v in ops(native[p], texts[p]).items():
                vs_n[k] += v
        res[name] = {"pages": len(pages),
                     "vs_claude": rate(vs_c, sum(len(claude[p]) for p in pages)),
                     "vs_native": rate(vs_n, sum(len(native[p]) for p in pages)),
                     "blank_page_chars": {p: len(texts[p]) for p in blank_pages if p in texts}}

    adj_f = SPOT / "adjudication.json"
    adj = json.loads(adj_f.read_text()) if adj_f.exists() else {}
    adj_total = {}
    for v in adj.values():
        for k, n in v.items():
            adj_total[k] = adj_total.get(k, 0) + n

    out = {"phase": "p1", "name": "claude-spotcheck", "source": Path(a.pdf).name,
           "text_pages": text_pages, "blank_pages": blank_pages,
           "claude_chars": n_claude, "native_chars": n_native,
           "native_vs_claude": rate(gt, n_claude), "native_vs_claude_by_page": gt_pages,
           "claude_blank_page_chars": {p: len(claude.get(p, "")) for p in blank_pages},
           "adjudication": {"total": adj_total, "by_page": adj},
           "engines": res}
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print(json.dumps({k: out[k] for k in ("native_vs_claude", "adjudication")}, ensure_ascii=False, indent=1))
    for name, r in res.items():
        print(f"{name:<40} 页 {r['pages']:>2}  对Claude CER {r['vs_claude']['cer']:.4f}  "
              f"对文字层 CER {r['vs_native']['cer']:.4f}  白页吐字 {sum(r['blank_page_chars'].values())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
