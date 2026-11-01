#!/usr/bin/env python3
"""小图补样: 再截 20 张小图对拍 RapidOCR, 看 P4 小图类不过是系统性问题还是样本偶然。只出数字。

用法: .venv/bin/python bench/p4_small.py --models <dir> [--units ane] [--seed 2] [--n 20]
截法与 p4_anysize 的 small 相同, 生成件落 work/bench/p4/small/。结果写 bench/results/p4-small.json。
"""
from __future__ import annotations

import argparse
import json
import random
import subprocess
import sys
from collections import Counter
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "bench"))

from rapidfuzz.distance import Levenshtein                # noqa: E402

from book_engines import _rapid_normalize, rapid_engine   # noqa: E402
from p4_parity import compare                             # noqa: E402

CLI = ROOT / ".build" / "release" / "ocr-cli"


def kind(c: str) -> str:
    return "space" if c.isspace() else ("alnum" if c.isalnum() else "punct")


def cut_split(ref: list, got: list, w: int, m: float = 4) -> dict:
    """编辑落在哪: 被裁切线切开的行端(贴图边那一头的 2 个字内)还是行内。行端的字本来就是残的, 两边读法不稳是预期。"""
    out = Counter()
    for l in ref:
        o = min(got, key=lambda g: abs(g["x"] - l["x"]) + abs(g["y"] - l["y"]), default=None)
        t, u = l["text"], o["text"] if o else ""
        left, right = l["x"] <= m, l["x"] + l["w"] >= w - m
        for op, i, _ in Levenshtein.editops(t, u):
            at_cut = (left and i <= 1) or (right and i >= len(t) - 2)
            out["edits_at_cut" if at_cut else "edits_inside"] += 1
        out["lines_cut"] += left or right
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--units", default="ane")
    ap.add_argument("--seed", type=int, default=2)
    ap.add_argument("--n", type=int, default=20)
    a = ap.parse_args()
    r = random.Random(a.seed)
    src = sorted((ROOT / "work/bench/p4/pages").glob("*.png"))
    T = ROOT / "work/bench/p4/small"
    T.mkdir(parents=True, exist_ok=True)
    for f in T.glob("*.png"):
        f.unlink()
    for i in range(a.n):
        im = Image.open(r.choice(src)).convert("L")
        w, h = r.randint(500, 1000), r.randint(300, 700)
        x, y = r.randint(0, im.width - w), r.randint(300, im.height - h - 200)
        im.crop((x, y, x + w, y + h)).save(T / f"small-{i:03d}.png")
    pngs = sorted(T.glob("*.png"))
    eng = rapid_engine(False)
    ref = {f.name: _rapid_normalize(eng(str(f), use_cls=False)) for f in pngs}
    of = ROOT / "work/bench/p4/small.json"
    rr = subprocess.run([str(CLI), "paddle", *map(str, pngs), "--models", a.models, "--units", a.units, "--no-orient", "--out", str(of)],
                        capture_output=True, text=True, cwd=ROOT)
    if rr.returncode:
        raise SystemExit(rr.stderr[-400:])
    res = json.loads(of.read_text("utf-8"))
    tot, ops, rows = Counter(), Counter(), []
    for f in pngs:
        c = compare(ref[f.name], res[str(f)])
        x, y = "".join(l["text"] for l in ref[f.name]), "".join(l["text"] for l in res[str(f)])
        e = Levenshtein.distance(x, y)
        for op, i, j in Levenshtein.editops(x, y):
            ops[kind(x[i] if op != "insert" else y[j])] += 1
        for k in ("ref", "got", "only_ref", "only_got", "text_equal"):
            tot[k] += c[k]
        tot["edits"] += e
        tot.update(cut_split(ref[f.name], res[str(f)], Image.open(f).width))
        tot["chars"] += len(x)
        rows.append({"image": f.name, "size": Image.open(f).size, "lines": c["ref"], "chars": len(x), "edits": e, "only_ref": c["only_ref"], "only_got": c["only_got"]})
    rate = round(1 - tot["edits"] / max(1, tot["chars"]), 4)
    clean = sum(1 for x in rows if x["edits"] == 0)
    inner = round(1 - tot["edits_inside"] / max(1, tot["chars"]), 4)
    out = {"phase": "p4", "name": "small-resample", "char_agreement_ignoring_cut": inner, "seed": a.seed, "criterion": "char_agreement >= 0.995", "units": a.units, "images": len(pngs),
           "total": dict(tot), "char_agreement": rate, "pass": rate >= 0.995, "images_identical": clean, "edit_kinds": dict(ops), "per_image": rows}
    (ROOT / "bench/results/p4-small.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print({k: out[k] for k in ("images", "total", "char_agreement", "char_agreement_ignoring_cut", "pass", "images_identical", "edit_kinds")})
    print(sorted(((x["edits"], x["image"], x["size"], x["lines"], x["chars"]) for x in rows), reverse=True)[:6])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
