#!/usr/bin/env python3
"""Phase 3 对拍: 同一份 fused.json 喂 book_pdf.embed 与 ocr-cli pdf。只出数字。

逐页内嵌图原始字节 md5、源文件前缀是否原样、逐行定位取回率(两边都用 book_pdf._verify 量一遍)、体积。
用法: .venv/bin/python bench/p3_pdf_parity.py <pdf> --tag en|zh
结果写 bench/results/p3-pdf-<tag>.json; 产物落 work/bench/p3/, 不进仓库。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

import pymupdf                                   # noqa: E402

import book_pdf                                  # noqa: E402

CLI = ROOT / ".build" / "release" / "ocr-cli"


def page_images(doc: pymupdf.Document) -> list[list[str]]:
    return [sorted(hashlib.md5(doc.xref_stream_raw(x[0])).hexdigest() for x in pg.get_images(full=True)) for pg in doc]


def boxes(fused: dict, doc: pymupdf.Document, font: pymupdf.Font) -> dict:
    """按 book_pdf.embed 的算法还原每行的落点, 让 _verify 量 Swift 产物时口径相同。"""
    out = {}
    for pj in fused["pages"]:
        if pj.get("native_text") or pj.get("text_source") == "native_text":
            continue
        pg = doc[pj["page"] - 1]
        sx, sy = pg.rect.width / pj["width"], pg.rect.height / pj["height"]
        items = []
        for ln in pj["lines"]:
            t = ln["text"].strip()
            if not t:
                continue
            X, Y, W, H = ln["x"] * sx, ln["y"] * sy, ln["w"] * sx, ln["h"] * sy
            fs = H * 0.95
            length = font.text_length(t, fs)
            if length > 0:
                fs *= W / length
            items.append((pymupdf.Rect(X, Y, X + W, Y + H), t, min(max(fs, 0.5), 1000.0)))
        if items:
            out[pj["page"] - 1] = items
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--fused", help="默认 work/bench/<名>.fused.json")
    a = ap.parse_args()
    src = Path(a.pdf).expanduser()
    fp = Path(a.fused) if a.fused else ROOT / "work" / "bench" / f"{src.stem}.fused.json"
    fused = json.loads(fp.read_text("utf-8"))
    tmp = ROOT / "work" / "bench" / "p3"
    tmp.mkdir(parents=True, exist_ok=True)

    t0 = time.time()
    py_out = tmp / f"{a.tag}.py.searchable.pdf"
    py = book_pdf.embed(src, fused, py_out, book_pdf.Options(force=True, verbose=False))
    t_py = time.time() - t0

    t0 = time.time()
    sw_out, sw_st = tmp / f"{a.tag}.swift.searchable.pdf", tmp / f"{a.tag}.swift.pdf-stats.json"
    r = subprocess.run([str(CLI), "pdf", str(src), str(fp), "--out", str(sw_out), "--force", "--stats", str(sw_st)],
                       capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"ocr-cli pdf 失败: {r.stderr[:400]}")
    t_sw = time.time() - t0
    st = json.loads(sw_st.read_text("utf-8"))

    sd, od = pymupdf.open(src), pymupdf.open(sw_out)
    a_img, b_img, c_img = page_images(sd), page_images(od), page_images(pymupdf.open(py_out))
    prefix = sw_out.read_bytes()[:src.stat().st_size] == src.read_bytes()
    warn: list[str] = []
    opts = book_pdf.Options(verbose=False)
    font = pymupdf.Font(book_pdf.FONT_NAME)
    chk = book_pdf._verify(sw_out, src, boxes(fused, sd, font), font, opts, warn)
    out = {"phase": "p3", "source": src.name, "pages": sd.page_count,
           "source_prefix_identical": prefix,
           "images_identical_swift": a_img == b_img, "image_pages_differ_swift": sum(x != y for x, y in zip(a_img, b_img)),
           "images_identical_python": a_img == c_img, "image_count": sum(map(len, a_img)),
           "size_in": src.stat().st_size,
           "size_python": py_out.stat().st_size, "size_swift": sw_out.stat().st_size,
           "delta_python": py_out.stat().st_size - src.stat().st_size, "delta_swift": sw_out.stat().st_size - src.stat().st_size,
           "seconds_python": round(t_py, 1), "seconds_swift": round(t_sw, 1),
           "producer_swift": od.metadata.get("producer"),
           "python": {k: py.get(k) for k in ("pages_embedded", "lines_written", "chars_in", "chars_retrieved", "retrieval", "line_retrieval", "retrieval_worst", "retrieval_worst_page")}
                     | {"probe": {k: py["probe"].get(k) for k in ("checked", "found", "missed", "outside_line_box", "mean_offset_pt", "max_offset_pt", "max_dy_pt")}},
           "swift_measured_by_python_verify": {k: chk.get(k) for k in ("chars_in", "chars_retrieved", "retrieval", "line_retrieval", "retrieval_worst", "retrieval_worst_page")}
                                              | {"probe": {k: chk["probe"].get(k) for k in ("checked", "found", "missed", "outside_line_box", "mean_offset_pt", "max_offset_pt", "max_dy_pt")}},
           "swift_self_check": {k: st.get(k) for k in ("pages_embedded", "pages_skipped_native", "pages_skipped_native_gate", "lines_written", "retrieval", "line_retrieval", "retrieval_worst", "retrieval_worst_page", "probe_checked", "probe_found", "probe_missed", "probe_outside", "probe_mean_offset_pt", "probe_max_offset_pt")},
           "python_verify_warnings": warn[:6], "swift_warnings": st.get("warnings", [])[:6]}
    (ROOT / "bench" / "results" / f"p3-pdf-{a.tag}.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0 if prefix and a_img == b_img else 1


if __name__ == "__main__":
    raise SystemExit(main())
