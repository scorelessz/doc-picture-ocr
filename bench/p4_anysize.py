#!/usr/bin/env python3
"""Phase 4 任意页面尺寸与整页方向: 随机生成各种开本的页图, Swift + Core ML 对拍 RapidOCR。只出数字。

用法: .venv/bin/python bench/p4_anysize.py --models <dir> [--units ane] [--seed 1]
页图来自 p4_parity 渲染的两本书(work/bench/p4/pages), 生成件落 work/bench/p4/synth/, 不进仓库。
结果写 bench/results/p4-anysize.json。
"""
from __future__ import annotations

import argparse
import json
import random
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "bench"))

from rapidfuzz.distance import Levenshtein                # noqa: E402

from book_engines import _rapid_normalize, rapid_engine   # noqa: E402
from p4_parity import compare                             # noqa: E402

CLI = ROOT / ".build" / "release" / "ocr-cli"
long_src: dict[str, list] = {}        # 超长页 → 拼它用的源页


def gen(r: random.Random, pages: list[Path], out: Path) -> dict[str, str]:
    kinds: dict[str, str] = {}
    long_src.clear()

    def load(p=None):
        return Image.open(p or r.choice(pages)).convert("L")

    def save(im, kind):
        f = out / f"{kind}-{len(kinds):03d}.png"
        im.save(f)
        kinds[f.name] = kind

    for _ in range(8):           # 随机缩放(含非等比轻微变形)
        im = load()
        s = r.uniform(0.35, 1.8)
        save(im.resize((int(im.width * s), int(im.height * s * r.uniform(0.97, 1.03))), Image.BILINEAR), "scale")
    for name, (w, h) in {"a4": (2480, 3508), "a5": (1748, 2480), "b5": (2079, 2953), "letter": (2550, 3300), "16k": (2126, 2835)}.items():
        im = load()              # 标准开本: 等比放进白底
        s = min(w / im.width, h / im.height) * 0.92
        c = im.resize((int(im.width * s), int(im.height * s)), Image.BILINEAR)
        bg = Image.new("L", (w, h), 245)
        bg.paste(c, ((w - c.width) // 2, (h - c.height) // 2))
        save(bg, "paper")
    for _ in range(5):           # 跨页横版
        a, b = load(), load()
        h = min(a.height, b.height)
        bg = Image.new("L", (a.width + b.width + 40, h), 240)
        bg.paste(a.crop((0, 0, a.width, h)), (0, 0))
        bg.paste(b.crop((0, 0, b.width, h)), (a.width + 40, 0))
        save(bg, "spread")
    for _ in range(3):           # 超长页
        names = r.sample(pages, r.choice((3, 4, 5)))
        ims = [load(p) for p in names]
        w = min(i.width for i in ims)
        bg = Image.new("L", (w, sum(i.height for i in ims)), 240)
        y = 0
        for i in ims:
            bg.paste(i.crop((0, 0, w, i.height)), (0, y))
            y += i.height
        long_src[f"long-{len(kinds):03d}.png"] = [(p, w) for p in names]
        save(bg, "long")
    for _ in range(4):           # 小图: 只截页面一块, 不缩放
        im = load()
        w, h = r.randint(500, 1000), r.randint(300, 700)
        x, y = r.randint(0, im.width - w), r.randint(300, im.height - h - 200)
        save(im.crop((x, y, x + w, y + h)), "small")
    for _ in range(3):           # 窄带: 宽高比 > 8
        im = load()
        h = r.randint(90, 150)
        y = r.randint(400, im.height - 500)
        save(im.crop((0, y, im.width, y + h)), "band")
    for _ in range(2):           # 超大
        im = load()
        save(im.resize((int(im.width * 2.6), int(im.height * 2.6)), Image.BILINEAR), "huge")
    return kinds


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--units", default="ane")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    r = random.Random(a.seed)
    src = sorted((ROOT / "work/bench/p4/pages").glob("*.png"))
    T = ROOT / "work/bench/p4/synth"
    T.mkdir(parents=True, exist_ok=True)
    for f in T.glob("*.png"):
        f.unlink()
    kinds = gen(r, src, T)
    pngs = sorted(T.glob("*.png"))
    eng = rapid_engine(False)
    # 超长页 RapidOCR 把长边缩到 2000, 自己都读成乱码, 不能当参照: 参照改成拼图用的源页各自的读法
    ref = {}
    for f in pngs:
        if f.name in long_src:
            ref[f.name] = []
            y = 0
            for p, w in long_src[f.name]:
                tmp = T / "src.tmp.png"
                im = Image.open(p).convert("L")
                im.crop((0, 0, w, im.height)).save(tmp)
                for l in _rapid_normalize(eng(str(tmp), use_cls=False)):
                    ref[f.name].append({**l, "y": l["y"] + y})
                y += im.height
                tmp.unlink()
        else:
            ref[f.name] = _rapid_normalize(eng(str(f), use_cls=False))

    of = ROOT / "work/bench/p4/synth.json"
    rr = subprocess.run([str(CLI), "paddle", *map(str, pngs), "--models", a.models, "--units", a.units, "--no-orient", "--out", str(of)],
                        capture_output=True, text=True, cwd=ROOT)
    if rr.returncode:
        raise SystemExit(rr.stderr[-400:])
    res = json.loads(of.read_text("utf-8"))
    groups: dict[str, dict] = {}
    worst = []
    for f in pngs:
        c = compare(ref[f.name], res[str(f)])
        g = groups.setdefault(kinds[f.name], {"images": 0, "ref": 0, "got": 0, "paired": 0, "text_equal": 0, "only_ref": 0, "only_got": 0, "iou_sum": 0.0, "edits": 0, "chars": 0})
        a_txt = "".join(l["text"] for l in ref[f.name])
        g["chars"] += len(a_txt)
        g["edits"] += Levenshtein.distance(a_txt, "".join(l["text"] for l in res[str(f)]))
        g["images"] += 1
        for k in ("ref", "got", "paired", "text_equal", "only_ref", "only_got"):
            g[k] += c[k]
        g["iou_sum"] += c["iou_sum"]
        worst.append((round(c["text_equal"] / max(1, c["ref"]), 3), f.name, c["ref"], c["got"], Image.open(f).size))
    tot = {k: sum(g[k] for g in groups.values()) for k in ("ref", "text_equal", "paired", "only_ref", "only_got", "edits", "chars")}
    for g in groups.values():
        g["rate"] = round(g["text_equal"] / max(1, g["ref"]), 4)
        g["char_agreement"] = round(1 - g["edits"] / max(1, g["chars"]), 4)
        g["mean_iou"] = round(g.pop("iou_sum") / max(1, g["paired"]), 4)
    # 判定口径: 字符一致率 ≥ 99.5%; 不足 20 行的类别样本太小, 只记录不判定
    for g in groups.values():
        g["judged"] = g["ref"] >= 20
        g["pass"] = g["char_agreement"] >= 0.995 if g["judged"] else None
    out = {"phase": "p4", "name": "any-size", "seed": a.seed, "criterion": "char_agreement >= 0.995, groups with >= 20 lines", "units": a.units, "images": len(pngs), "total": tot,
           "text_equal_rate": round(tot["text_equal"] / max(1, tot["ref"]), 4),
           "char_agreement": round(1 - tot["edits"] / max(1, tot["chars"]), 4), "groups": groups,
           "worst": sorted(worst)[:8], "timing": rr.stdout.strip()}

    # 整页方向: 把书页转过去, 应转回来读出和正放时相同的文字
    rot = {}
    sample = r.sample([p for p in src], 8)
    R = T / "rot"
    R.mkdir(exist_ok=True)
    upright = {p.name: _rapid_normalize(eng(str(p), use_cls=False)) for p in sample}
    for deg in (0, 90, 180, 270):
        fs = []
        for p in sample:
            f = R / f"{p.stem}-r{deg}.png"
            Image.open(p).convert("L").rotate(-deg, expand=True).save(f)   # PIL 逆时针为正, 这里顺时针转 deg 模拟扫错方向
            fs.append(f)
        of2 = ROOT / f"work/bench/p4/rot{deg}.json"
        p2 = subprocess.run([str(CLI), "paddle", *map(str, fs), "--models", a.models, "--units", a.units, "--out", str(of2)],
                            capture_output=True, text=True, cwd=ROOT)
        if p2.returncode:
            raise SystemExit(p2.stderr[-400:])
        got = json.loads(of2.read_text("utf-8"))
        same = want = 0
        pages_ok = 0
        for p, f in zip(sample, fs):
            texts = [l["text"] for l in got[str(f)]]
            base = [l["text"] for l in upright[p.name]]
            hit = len(set(base) & set(texts))
            same += hit
            want += len(set(base))
            pages_ok += hit >= 0.9 * max(1, len(set(base)))
        rot[str(deg)] = {"pages": len(sample), "pages_recovered": pages_ok, "line_recovery": round(same / max(1, want), 4), "timing": p2.stdout.strip()[:120]}
    out["orientation"] = rot
    (ROOT / "bench/results/p4-anysize.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print(json.dumps({k: out[k] for k in ("images", "total", "text_equal_rate", "char_agreement")}, ensure_ascii=False))
    for k, g in groups.items():
        print(k, g)
    print(out["worst"][:6]); print(rot); print(out["timing"][:220])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
