#!/usr/bin/env python3
"""Phase 3 嵌字合成件: 四种旋转 × CropBox × xref 表/xref 流+对象流, 用 pymupdf 独立量文字落点。只出数字。

BOOKS.md「踩过的坑」: 旋转页坐标、CropBox 平移、CTM 残留。每页在已知显示位置画一行可见字,
fused 给同一位置, ocr-cli pdf 嵌字后用 pymupdf 取字心(乘 rotation_matrix), 偏差须在行框之内。
结果写 bench/results/p3-pdf-synth.json。
"""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
import pymupdf                                   # noqa: E402

CLI = ROOT / ".build" / "release" / "ocr-cli"
T = ROOT / "work" / "bench" / "p3" / "pdfsyn"


def make(path: Path, objstm: bool) -> list[dict]:
    doc = pymupdf.open()
    cases = []
    for rot in (0, 90, 180, 270):
        for crop in (None, (30, 30, 400, 535), (20, 60, 380, 575)):   # 上下留白不对称
            p = doc.new_page(width=420, height=595)
            pix = pymupdf.Pixmap(pymupdf.csGRAY, pymupdf.IRect(0, 0, 200, 200), False)
            pix.set_rect(pix.irect, (235,))
            p.insert_image(p.rect, pixmap=pix)
            # 留一个没闭合的 q 和缩放: 文字层不能被原内容的状态带偏
            xr = p.get_contents()[0]
            doc.update_stream(xr, b"q 1 0 0 1 0 0 cm\n" + doc.xref_stream(xr))
            if crop:
                p.set_cropbox(pymupdf.Rect(*crop))
            p.set_rotation(rot)
            cases.append({"rot": rot, "crop": crop})
    if objstm:
        doc.save(path, garbage=1, deflate=True, use_objstms=1)
    else:
        doc.save(path, garbage=1, deflate=True)
    doc.close()
    return cases


def run(objstm: bool) -> dict:
    src = T / f"syn-{int(objstm)}.pdf"
    cases = make(src, objstm)
    doc = pymupdf.open(src)
    pages = []
    want = {}
    for i, c in enumerate(cases, 1):
        pg = doc[i - 1]
        w, h = pg.rect.width, pg.rect.height
        z = 2.0
        lines = []
        for k, (fx, fy, t) in enumerate(((0.1, 0.1, "左上第一行 abc"), (0.3, 0.5, "居中行 mid 中文"), (0.2, 0.85, "底部行 tail"))):
            lines.append({"x": fx * w * z, "y": fy * h * z, "w": 0.5 * w * z, "h": 24.0, "text": t,
                          "conf": 0.9, "src": "both", "alt": None, "flag": "ok"})
        pages.append({"page": i, "width": round(w * z), "height": round(h * z), "pdf_width": w, "pdf_height": h,
                      "zoom": z, "rotation": c["rot"], "native_text": False, "lines": lines})
        want[i] = lines
    fused = {"source": str(src), "dpi": 144, "engines": ["vision", "rapidocr"], "pages": pages,
             "stats": {"pages": len(pages), "lines": 0, "both": 0, "only_vision": 0, "only_rapidocr": 0, "divergent": 0,
                       "low_conf": 0, "glossary_hits": 0, "dropped_empty": 0, "dropped_contained": 0}}
    fp = T / f"syn-{int(objstm)}.fused.json"
    fp.write_text(json.dumps(fused, ensure_ascii=False), "utf-8")
    out, st = T / f"syn-{int(objstm)}.out.pdf", T / f"syn-{int(objstm)}.stats.json"
    r = subprocess.run([str(CLI), "pdf", str(src), str(fp), "--out", str(out), "--force", "--stats", str(st)],
                       capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"ocr-cli pdf 失败: {r.stderr[:400]}")
    res = {"objstm": objstm, "pages": len(cases), "prefix_identical": out.read_bytes()[:src.stat().st_size] == src.read_bytes(),
           "swift": {k: v for k, v in json.loads(st.read_text()).items() if k in
                     ("retrieval", "line_retrieval", "probe_found", "probe_missed", "probe_outside", "probe_max_offset_pt", "pages_rotated")}}
    od = pymupdf.open(out)
    bad = []
    maxdy = maxdx = 0.0
    for i, c in enumerate(cases, 1):
        pg = od[i - 1]
        rm = pymupdf.Matrix(pg.rotation_matrix) if pg.rotation else None
        src_pg = doc[i - 1]
        sx, sy = src_pg.rect.width / pages[i - 1]["width"], src_pg.rect.height / pages[i - 1]["height"]
        chars = []
        for b in pg.get_text("rawdict")["blocks"]:
            for l in b.get("lines", []):
                for s in l["spans"]:
                    for ch in s["chars"]:
                        r0 = pymupdf.Rect(ch["bbox"])
                        if rm is not None:
                            r0 = r0 * rm
                        r0.normalize()
                        chars.append(((r0.x0 + r0.x1) / 2, (r0.y0 + r0.y1) / 2, ch["c"]))
        for ln in want[i]:
            x0, y0, x1, y1 = ln["x"] * sx, ln["y"] * sy, (ln["x"] + ln["w"]) * sx, (ln["y"] + ln["h"]) * sy
            first = ln["text"][0]
            got = [c2 for c2 in chars if c2[2] == first]
            if not got:
                bad.append({"page": i, "rot": c["rot"], "crop": c["crop"], "why": "没取到字"})
                continue
            best = min(got, key=lambda p: abs(p[0] - x0) + abs(p[1] - (y0 + y1) / 2))
            dx, dy = abs(best[0] - x0), abs(best[1] - (y0 + y1) / 2)
            maxdx, maxdy = max(maxdx, dx), max(maxdy, dy)
            if dy > (y1 - y0) or dx > (x1 - x0) / max(1, len(ln["text"])) * 2.5:
                bad.append({"page": i, "rot": c["rot"], "crop": c["crop"], "dx": round(dx, 2), "dy": round(dy, 2)})
    res.update({"bad": len(bad), "first_bad": bad[:6], "max_dx_pt": round(maxdx, 2), "max_dy_pt": round(maxdy, 2)})
    return res


def main() -> int:
    T.mkdir(parents=True, exist_ok=True)
    out = {"phase": "p3", "name": "pdf-synth", "runs": [run(False), run(True)]}
    (ROOT / "bench" / "results" / "p3-pdf-synth.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print(json.dumps(out, ensure_ascii=False))
    return 1 if any(r["bad"] or not r["prefix_identical"] for r in out["runs"]) else 0


if __name__ == "__main__":
    raise SystemExit(main())
