#!/usr/bin/env python3
"""上传图片格式对读字的影响: 抽查页存成不同格式, 本地 PaddleOCR-VL 读, 对 v2 真值算 CER。不发任何线上请求, 只出数字。

页图来自 bench/p5_block_eval.py 渲染的 work/bench/p5/block/{en,zh}/p*.png。结果写 bench/results/p8-upload-format.json。
本地模型只是代理, 线上模型的结果要另外验证。
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))

from rapidfuzz.distance import Levenshtein       # noqa: E402

from p3_fuse_parity import norm_text             # noqa: E402

VL = Path.home() / "Library/Application Support/DocOCR/models/vl"
CLI = ROOT / "work/p8/ocr-cli-eval/ocr-cli"
BOOKS = {"en": ("work/bench/spot-en2", [3]), "zh": ("work/bench/spot-zh", [])}
VARIANTS = {"png-1792": (1792, "png"), "jpeg90-1792": (1792, "jpeg"), "jpeg90-1280": (1280, "jpeg"), "jpeg75-1792": (1792, "jpeg75")}


def main() -> int:
    out = {"phase": "p8", "name": "upload-format", "note": "本地 PaddleOCR-VL 作代理, 灰度页图; bytes 是编码后图片, 请求体还要加 base64 的 33%"}
    for tag, (spot, ex) in BOOKS.items():
        truth = {int(k): v for k, v in json.loads((ROOT / spot / "truth.json").read_text("utf-8")).items()}
        pages = sorted(p for p in truth if p not in ex)
        T = ROOT / f"work/p8/format/{tag}"
        T.mkdir(parents=True, exist_ok=True)
        out[tag] = {}
        for name, (edge, fmt) in VARIANTS.items():
            files, sizes = [], 0
            for p in pages:
                im = Image.open(ROOT / f"work/bench/p5/block/{tag}/p{p:04d}.png").convert("L")
                k = min(1, edge / max(im.size))
                if k < 1:
                    im = im.resize((int(im.width * k), int(im.height * k)), Image.LANCZOS)
                f = T / f"{name}-p{p:04d}.{'png' if fmt == 'png' else 'jpg'}"
                im.save(f, **({"optimize": False} if fmt == "png" else {"quality": 75 if fmt == "jpeg75" else 90}))
                files.append(f)
                sizes += f.stat().st_size
            j = T / f"{name}.json"
            r = subprocess.run([str(CLI), "vl", *map(str, files), "--vl-model", str(VL), "--out", str(j)], capture_output=True, text=True, cwd=ROOT)
            if r.returncode:
                raise SystemExit(r.stderr[-300:])
            got = json.loads(j.read_text("utf-8"))
            edits = chars = 0
            for p, f in zip(pages, files):
                a, b = norm_text(truth[p]), norm_text(got[str(f)])
                edits += Levenshtein.distance(a, b)
                chars += len(a)
            out[tag][name] = {"pages": len(pages), "mean_kb": round(sizes / len(pages) / 1024, 1), "edits": edits, "chars": chars, "cer": round(edits / chars, 5)}
            print(tag, name, out[tag][name], flush=True)
    (ROOT / "bench/results/p8-upload-format.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
