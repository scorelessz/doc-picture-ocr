#!/usr/bin/env python3
"""整页漏识别诊断: 指定页的内嵌图结构、渲染图像素统计、两引擎各渲染方式下认出几行。

只输出数字和结构信息, 不输出任何识别文本。页图写在 work/bench/diag/(已被 .gitignore 挡住)。

用法:
  .venv/bin/python bench/diag_pages.py <pdf> 10 20 62 [--out bench/diag-pages.json]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

import pymupdf                                   # noqa: E402

from book_engines import _rapid_normalize, rapid_engine, vision_page  # noqa: E402
from book_render import choose_dpi              # noqa: E402


def pixel_stats(pix: pymupdf.Pixmap) -> dict:
    """灰度图: 均值与暗像素占比。全白页均值≈255、暗像素≈0。"""
    import numpy as np
    a = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, pix.n)
    g = a[..., 0] if pix.n == 1 else a[..., :3].mean(axis=2)
    return {"w": pix.width, "h": pix.height, "mean": round(float(g.mean()), 1),
            "dark_lt128": round(float((g < 128).mean()), 4),
            "dark_lt200": round(float((g < 200).mean()), 4)}


def images(page: pymupdf.Page) -> list[dict]:
    bbox = {i.get("xref"): i.get("bbox") for i in page.get_image_info(xrefs=True)}
    out = []
    for xref, smask, w, h, bpc, cs, _alt, _name, filt, *_ in page.get_images(full=True):
        b = bbox.get(xref)
        out.append({"xref": xref, "smask": smask, "w": w, "h": h, "bpc": bpc,
                    "colorspace": cs, "filter": filt,
                    "bbox": [round(v, 1) for v in b] if b else None})
    return out


def ocr_counts(png: Path) -> dict:
    v = vision_page(png)
    r = _rapid_normalize(rapid_engine(False)(str(png)))
    return {"vision_lines": len(v), "vision_chars": sum(len(x["text"]) for x in v),
            "rapidocr_lines": len(r), "rapidocr_chars": sum(len(x["text"]) for x in r)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("pages", nargs="+", type=int)
    ap.add_argument("--out", default=str(ROOT / "bench" / "diag-pages.json"))
    a = ap.parse_args()

    doc = pymupdf.open(Path(a.pdf).expanduser())
    tmp = ROOT / "work" / "bench" / "diag"
    tmp.mkdir(parents=True, exist_ok=True)
    res = []
    for pno in a.pages:
        page = doc[pno - 1]
        dpi = choose_dpi(page)
        row = {"page": pno, "pipeline_dpi": dpi, "images": images(page), "renders": {}}
        #  流水线的渲染方式(灰度 @ choose_dpi) + 三个对照: 彩色同 dpi、灰度 300、灰度 150
        for key, d, cs in (("gray_pipeline", dpi, pymupdf.csGRAY),
                           ("rgb_pipeline", dpi, pymupdf.csRGB),
                           ("gray_300", 300, pymupdf.csGRAY),
                           ("gray_150", 150, pymupdf.csGRAY)):
            z = d / 72.0
            pix = page.get_pixmap(matrix=pymupdf.Matrix(z, z), colorspace=cs, alpha=False)
            png = tmp / f"p{pno:04d}-{key}.png"
            pix.save(str(png))
            row["renders"][key] = {**pixel_stats(pix), **ocr_counts(png)}
        res.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
    Path(a.out).write_text(json.dumps(res, ensure_ascii=False, indent=1) + "\n", "utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
