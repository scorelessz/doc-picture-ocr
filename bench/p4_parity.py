#!/usr/bin/env python3
"""Phase 4 门槛: 同一批页图上 Swift + Core ML 与 RapidOCR 逐行比。只出数字。

门槛: 文字逐行一致率 ≥ 98%, 几何框基本重合。对三种 computeUnits 各跑一遍, 记每页耗时。
用法: .venv/bin/python bench/p4_parity.py --models ~/Desktop/Ignore/models/coreml [--units all,ane,cpu] [--pages 40]
结果写 bench/results/p4-parity.json; 页图落 work/bench/p4/pages/, 不进仓库。
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from book_engines import _rapid_normalize, rapid_engine   # noqa: E402

CLI = ROOT / ".build" / "release" / "ocr-cli"
BOOKS = {"en": ("City of Broken Promises", 360, [3, 8, 9, 11, 12, 50, 120, 185, 236, 300]),
         "zh": ("失约之城", 300, [7, 15, 18, 27, 30, 50, 100, 113, 150, 164])}


def iou(a: dict, b: dict) -> float:
    ix = max(0.0, min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"]))
    iy = max(0.0, min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"]))
    i = ix * iy
    u = a["w"] * a["h"] + b["w"] * b["h"] - i
    return i / u if u > 0 else 0.0


def compare(ref: list[dict], got: list[dict]) -> dict:
    used, pairs = set(), []
    for r in ref:
        best, bv = None, 0.3
        for j, g in enumerate(got):
            if j in used:
                continue
            v = iou(r, g)
            if v > bv:
                best, bv = j, v
        if best is not None:
            used.add(best)
            pairs.append((r, got[best], bv))
    same = sum(1 for r, g, _ in pairs if r["text"] == g["text"])
    dev = max((abs(r[k] - g[k]) for r, g, _ in pairs for k in "xywh"), default=0.0)
    return {"ref": len(ref), "got": len(got), "paired": len(pairs), "text_equal": same, "only_ref": len(ref) - len(pairs),
            "only_got": len(got) - len(pairs), "iou_sum": sum(v for *_, v in pairs), "max_dev_px": dev,
            "diff": [(r["text"], g["text"]) for r, g, _ in pairs if r["text"] != g["text"]]}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--units", default="all,ane,cpu")
    ap.add_argument("--cls", action="store_true", help="两边都开逐行方向分类(RapidOCR 默认开)")
    a = ap.parse_args()
    T = ROOT / "work" / "bench" / "p4" / "pages"
    T.mkdir(parents=True, exist_ok=True)
    pngs = []
    for tag, (stem, dpi, pages) in BOOKS.items():
        src = Path.home() / "Desktop" / "Ignore" / f"{stem}.pdf"
        for p in pages:
            f = T / f"{tag}-p{p:04d}.png"
            if not f.exists():
                subprocess.run([str(CLI), "render", str(src), "--page", str(p), "--dpi", str(dpi), "--out", str(f)], check=True)
            pngs.append(f)

    cache = ROOT / "work" / "bench" / "p4" / f"rapid-ref{'-cls' if a.cls else ''}.json"
    if cache.exists():
        ref = json.loads(cache.read_text("utf-8"))
    else:
        eng = rapid_engine(False)
        ref, t0 = {}, time.time()
        for f in pngs:
            ref[f.name] = _rapid_normalize(eng(str(f), use_cls=a.cls))
        ref["_seconds_per_page"] = round((time.time() - t0) / len(pngs), 3)
        cache.write_text(json.dumps(ref, ensure_ascii=False), "utf-8")

    out = {"phase": "p4", "name": "paddle-parity", "pages": len(pngs), "cls": a.cls, "rapidocr_sec_per_page": ref["_seconds_per_page"], "units": {}}
    detail = {}
    for u in a.units.split(","):
        of = ROOT / "work" / "bench" / "p4" / f"swift-{u}.json"
        r = subprocess.run([str(CLI), "paddle", *map(str, pngs), "--models", a.models, "--units", u, "--out", str(of)] + (["--cls"] if a.cls else []),
                           capture_output=True, text=True, cwd=ROOT)
        if r.returncode:
            out["units"][u] = {"error": r.stderr[-300:]}
            continue
        res = json.loads(of.read_text("utf-8"))
        tot = {"ref": 0, "got": 0, "paired": 0, "text_equal": 0, "only_ref": 0, "only_got": 0}
        iou_sum, dev, diffs, per = 0.0, 0.0, [], {}
        for f in pngs:
            c = compare(ref[f.name], res[str(f)])
            for k in tot:
                tot[k] += c[k]
            iou_sum += c["iou_sum"]
            dev = max(dev, c["max_dev_px"])
            diffs += [(f.name, *d) for d in c["diff"]]
            per[f.name] = {k: c[k] for k in ("ref", "got", "text_equal", "only_ref", "only_got")}
        m = re.search(r"载入 ([\d.]+)s\s+首页 ([\d.]+)s\s+其余均值 ([\d.]+)s/页 \| (.*)", r.stdout)
        out["units"][u] = {**tot, "text_equal_rate": round(tot["text_equal"] / max(1, tot["ref"]), 4),
                           "mean_iou": round(iou_sum / max(1, tot["paired"]), 4), "max_dev_px": round(dev, 1),
                           "load_seconds": float(m[1]) if m else None, "first_page_seconds": float(m[2]) if m else None,
                           "sec_per_page": float(m[3]) if m else None, "stages_total": m[4] if m else r.stdout[-200:],
                           "per_page": per}
        detail[u] = diffs
        print(u, {k: v for k, v in out["units"][u].items() if k != "per_page"}, flush=True)
    (ROOT / "bench" / "results" / "p4-parity.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    (ROOT / "work" / "bench" / "p4" / "diffs.json").write_text(json.dumps(detail, ensure_ascii=False, indent=0), "utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
