#!/usr/bin/env python3
"""Claude 多模态抽查 · 准备: 把抽查页切成条带图, 供 Mac 上的 Claude 会话逐条看图转写。

全部产物落在 work/bench/spot/(已被 .gitignore 挡住), 含书的原文, **不提交**:
  pNNNN.png            整页图(流水线同款渲染)
  pNNNN-sKK.png        条带图: 按原生文字层的行框, 每 --per-strip 行一条, 上下留白
  pNNNN.native.json    原生文字层逐行文本 + 行框(条带号对应)
  manifest.json        页 → 条带清单; 白页标记(渲染图暗像素 < 0.1%)

没有原生文字层的书(纯扫描件)改用 P0 融合结果的行框切条带(--boxes fused, 默认 auto 自动选);
此时 native.json 里是融合读法, 只用来定位条带, **不是真值**。

用法:
  .venv/bin/python bench/spot_prep.py <pdf> 3 8 9 11 12 [--per-strip 6] [--boxes auto|native|fused]
        [--out-dir work/bench/spot-zh]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

import numpy as np                               # noqa: E402
import pymupdf                                   # noqa: E402
from PIL import Image                            # noqa: E402

from book_render import choose_dpi              # noqa: E402

OUT = ROOT / "work" / "bench" / "spot"
MIN_NATIVE_LINES = 3
BLANK_DARK = 0.001


def native_lines(page: pymupdf.Page) -> list[dict]:
    """原生文字层按行取出(页面点坐标), 按 y 再按 x 排序。"""
    out = []
    for b in page.get_text("dict")["blocks"]:
        for ln in b.get("lines", []):
            text = "".join(s["text"] for s in ln["spans"])
            if text.strip():
                x0, y0, x1, y1 = ln["bbox"]
                out.append({"text": text, "bbox": [x0, y0, x1, y1]})
    out.sort(key=lambda r: (round(r["bbox"][1] / 4), r["bbox"][0]))
    return out


def fused_lines(fpage: dict, z: float) -> list[dict]:
    """P0 融合结果的行框(像素, 按该页 zoom)换算成页面点坐标, 与 native_lines 同形。"""
    fz = fpage.get("zoom") or z
    out = [{"text": l["text"], "bbox": [l["x"] / fz, l["y"] / fz,
                                        (l["x"] + l["w"]) / fz, (l["y"] + l["h"]) / fz]}
           for l in fpage.get("lines", []) if l.get("text", "").strip()]
    out.sort(key=lambda r: (round(r["bbox"][1] / 4), r["bbox"][0]))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("pages", nargs="+", type=int)
    ap.add_argument("--per-strip", type=int, default=6)
    ap.add_argument("--boxes", choices=("auto", "native", "fused"), default="auto")
    ap.add_argument("--out-dir", default=str(OUT))
    a = ap.parse_args()

    pdf = Path(a.pdf).expanduser()
    doc = pymupdf.open(pdf)
    out_dir = Path(a.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    fused = {}
    fp = ROOT / "work" / "bench" / f"{pdf.stem}.fused.json"
    if a.boxes != "native" and fp.exists():
        fused = {pg["page"]: pg for pg in json.loads(fp.read_text("utf-8"))["pages"]}
    manifest = {}
    for pno in a.pages:
        page = doc[pno - 1]
        z = choose_dpi(page) / 72.0
        pix = page.get_pixmap(matrix=pymupdf.Matrix(z, z), colorspace=pymupdf.csGRAY, alpha=False)
        img = Image.frombytes("L", (pix.width, pix.height), pix.samples)
        img.save(out_dir / f"p{pno:04d}.png")
        dark = float((np.asarray(img) < 128).mean())
        lines = native_lines(page) if a.boxes != "fused" else []
        source = "native"
        if a.boxes != "native" and len(lines) < MIN_NATIVE_LINES:
            if pno not in fused:
                raise SystemExit(f"p{pno} 没有原生文字层, 又缺 P0 融合结果 {fp}")
            lines, source = fused_lines(fused[pno], z), "fused"
        strips = []
        for k in range(0, len(lines), a.per_strip):
            grp = lines[k:k + a.per_strip]
            y0 = min(l["bbox"][1] for l in grp) * z
            y1 = max(l["bbox"][3] for l in grp) * z
            pad = 0.6 * (y1 - y0) / max(1, len(grp))
            box = (0, max(0, round(y0 - pad)), img.width, min(img.height, round(y1 + pad)))
            name = f"p{pno:04d}-s{len(strips):02d}.png"
            img.crop(box).save(out_dir / name)
            for l in grp:
                l["strip"] = len(strips)
            strips.append(name)
        (out_dir / f"p{pno:04d}.native.json").write_text(
            json.dumps(lines, ensure_ascii=False, indent=1), "utf-8")
        manifest[pno] = {"page_png": f"p{pno:04d}.png", "strips": strips,
                         "native_lines": len(lines), "boxes": source, "dark_lt128": round(dark, 4),
                         "blank": dark < BLANK_DARK}
        print(f"p{pno}: {len(lines)} 行 → {len(strips)} 条带, 暗像素 {dark:.4f}"
              + ("  [白页]" if dark < BLANK_DARK else ""))
    (out_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1), "utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
