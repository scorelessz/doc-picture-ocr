#!/usr/bin/env python3
"""块级 VLM 评估: 只把分歧行所在的块裁图喂 PaddleOCR-VL, 与整页比耗时、CER、编造。只出数字。

块 = 分歧行加上下各一行, 相邻的并起来。块的文字按页序拼成一页 VLM 文本走 vlm-fuse。
要先跑 work/bench/p5/full 的整本基线。结果写 bench/results/p5-block.json。
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))

from p3_fuse_parity import cer                   # noqa: E402

CLI = ROOT / ".build" / "release" / "ocr-cli"
VL = Path.home() / "Library/Application Support/DocOCR/models/vl"
BOOKS = {"en": ("City of Broken Promises", "work/bench/spot-en2", [3]), "zh": ("失约之城", "work/bench/spot-zh", [])}


def blocks(p: dict) -> list[list[dict]]:
    ls = sorted(p["lines"], key=lambda l: (l["y"], l["x"]))
    d = [l.get("flag") == "divergent" for l in ls]
    use = [any(d[max(0, i - 1):i + 2]) for i in range(len(ls))]
    out, cur = [], []
    for l, u in zip(ls, use):
        if u:
            cur.append(l)
        elif cur:
            out.append(cur)
            cur = []
    return out + ([cur] if cur else [])


def run_vl(pngs: list[Path], out: Path) -> tuple[dict, float]:
    t0 = time.time()
    r = subprocess.run([str(CLI), "vl", *map(str, pngs), "--vl-model", str(VL), "--out", str(out)], capture_output=True, text=True, cwd=ROOT)
    if r.returncode:
        raise SystemExit(r.stderr[-300:])
    return json.loads(out.read_text("utf-8")), round(time.time() - t0, 1)


def fuse(fused: Path, texts: Path, tag: str, name: str) -> tuple[dict, dict]:
    o, rp = texts.parent / f"{name}.fused.json", texts.parent / f"{name}.rep.json"
    r = subprocess.run([str(CLI), "vlm-fuse", str(fused), "--vlm-dir", str(texts), "--out", str(o), "--report", str(rp)], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr[-300:])
    return json.loads(o.read_text("utf-8")), json.loads(rp.read_text("utf-8"))


def looped(t: str) -> bool:
    return bool(re.search(r"(.{2,80}?)\1{4,}\s*$", t, re.S))


def main() -> int:
    out = {"phase": "p5", "name": "vlm-block"}
    for tag, (stem, spot, ex) in BOOKS.items():
        pdf = Path.home() / "Desktop/Ignore" / f"{stem}.pdf"
        fp = ROOT / f"work/bench/p5/full/{tag}-base/w/{stem}.fused.json"
        T = ROOT / f"work/bench/p5/block/{tag}"
        (T / "page").mkdir(parents=True, exist_ok=True)
        (T / "block").mkdir(exist_ok=True)
        doc = json.loads(fp.read_text("utf-8"))
        truth = {int(k): v for k, v in json.loads((ROOT / spot / "truth.json").read_text("utf-8")).items()}
        pages = sorted(p for p in truth if p not in ex)
        whole, crops, owner = [], [], {}
        for p in doc["pages"]:
            if p["page"] not in pages:
                continue
            png = T / f"p{p['page']:04d}.png"
            subprocess.run([str(CLI), "render", str(pdf), "--page", str(p["page"]), "--dpi", str(p["zoom"] * 72), "--out", str(png)], check=True, capture_output=True)
            whole.append(png)
            im = Image.open(png).convert("L")
            for i, b in enumerate(blocks(p)):
                m = max(8, sorted(l["h"] for l in b)[len(b) // 2] * 0.5)
                box = (max(0, int(min(l["x"] for l in b) - m)), max(0, int(min(l["y"] for l in b) - m)),
                       min(im.width, int(max(l["x"] + l["w"] for l in b) + m)), min(im.height, int(max(l["y"] + l["h"] for l in b) + m)))
                f = T / f"b{p['page']:04d}-{i:02d}.png"
                im.crop(box).save(f)
                crops.append(f)
                owner[str(f)] = (p["page"], i, "".join(l["text"] for l in b))
        (texts_w, sec_w), (texts_b, sec_b) = run_vl(whole, T / "whole.json"), run_vl(crops, T / "crops.json")
        for f, t in texts_w.items():
            (T / "page" / (Path(f).stem + ".txt")).write_text(t, "utf-8")
        byp: dict[int, list] = {}
        over = loops = 0
        for f, t in texts_b.items():
            pg, i, ctc = owner[f]
            byp.setdefault(pg, []).append((i, t))
            over += len(t.replace(" ", "")) > len(ctc.replace(" ", "")) * 1.5 + 50
            loops += looped(t)
        for pg, v in byp.items():
            (T / "block" / f"p{pg:04d}.txt").write_text("\n".join(t for _, t in sorted(v)), "utf-8")
        fw, rpw = fuse(fp, T / "page", tag, "w")
        fb, rpb = fuse(fp, T / "block", tag, "b")
        base = json.loads(fp.read_text("utf-8"))
        cw, cb, c0 = cer(fw, truth, pages), cer(fb, truth, pages), cer(base, truth, pages)
        out[tag] = {"pages": len(pages), "crops": len(crops), "whole_seconds": sec_w, "block_seconds": sec_b,
                    "cer_two_engine": c0["cer"], "cer_whole": cw["cer"], "cer_block": cb["cer"],
                    "flips_whole": sum(x["flips"] for x in rpw), "flips_block": sum(x["flips"] for x in rpb),
                    "orphans_whole": sum(x["orphans"] for x in rpw), "orphan_chars_whole": sum(x["orphan_chars"] for x in rpw),
                    "orphans_block": sum(x["orphans"] for x in rpb), "orphan_chars_block": sum(x["orphan_chars"] for x in rpb),
                    "crops_over_length": over, "crops_looped": loops}
        print(tag, out[tag])
    (ROOT / "bench/results/p5-block.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
