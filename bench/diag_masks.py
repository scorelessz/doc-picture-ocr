#!/usr/bin/env python3
"""逐页拆开内嵌图: 前景图 / 软蒙版(SMask)各自的像素统计 + MuPDF 渲染时的告警。只出数字。

判断「前景文字图 + SMask」这种分层(MRC)结构里, 是哪一层在 MuPDF 下没画出来。

用法:
  .venv/bin/python bench/diag_masks.py <pdf> 10 20 3 11 [--out bench/diag-masks.json]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pymupdf

ROOT = Path(__file__).resolve().parent.parent


def stats(pix: pymupdf.Pixmap) -> dict:
    a = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, pix.n)
    g = a[..., 0] if pix.n == 1 else a[..., :3].mean(axis=2)
    return {"w": pix.width, "h": pix.height, "n": pix.n, "mean": round(float(g.mean()), 1),
            "lt128": round(float((g < 128).mean()), 4), "gt128": round(float((g > 128).mean()), 4)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("pages", nargs="+", type=int)
    ap.add_argument("--out", default=str(ROOT / "bench" / "diag-masks.json"))
    a = ap.parse_args()

    doc = pymupdf.open(Path(a.pdf).expanduser())
    res = []
    for pno in a.pages:
        page = doc[pno - 1]
        pymupdf.TOOLS.reset_mupdf_warnings()
        page.get_pixmap(matrix=pymupdf.Matrix(2, 2), alpha=False)
        warn = pymupdf.TOOLS.mupdf_warnings()
        row = {"page": pno, "mupdf_warnings": warn.splitlines()[:10] if warn else [], "images": []}
        for xref, smask, *_ in page.get_images(full=True):
            item = {"xref": xref, "smask": smask}
            try:
                item["image"] = stats(pymupdf.Pixmap(doc, xref))
            except Exception as e:                     # noqa: BLE001
                item["image_error"] = f"{type(e).__name__}: {e}"[:160]
            if smask:
                try:
                    item["mask"] = stats(pymupdf.Pixmap(doc, smask))
                except Exception as e:                 # noqa: BLE001
                    item["mask_error"] = f"{type(e).__name__}: {e}"[:160]
                obj = doc.xref_object(smask, compressed=True)
                item["mask_dict"] = {k: doc.xref_get_key(smask, k)[1]
                                     for k in ("Filter", "BitsPerComponent", "ColorSpace",
                                               "Matte", "Decode", "Width", "Height")
                                     if doc.xref_get_key(smask, k)[0] != "null"}
                item["mask_dict_len"] = len(obj)
            row["images"].append(item)
        res.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
    Path(a.out).write_text(json.dumps(res, ensure_ascii=False, indent=1) + "\n", "utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
