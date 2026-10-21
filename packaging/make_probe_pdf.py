#!/usr/bin/env python3
"""造一份「扫描件样子」的一页 PDF，给打包验收当探针用。

纯图像页（文字先渲成位图再贴进 PDF），所以它会真的走完渲染 → 双引擎 OCR →
融合 → Markdown → 嵌字这五步，而不是被当成「已有原生文字层」跳过。

    .venv/bin/python packaging/make_probe_pdf.py /tmp/probe.pdf
"""
from __future__ import annotations

import sys
from pathlib import Path

import pymupdf

TEXT = [
    "第一章　打包探针",
    "",
    "这一页是打包验收用的合成扫描件。它的作用只有一个：",
    "让打好的程序把渲染、双引擎识别、裁决、段落合并和隐形",
    "文字层这五个步骤真正各走一遍，任何一环缺了依赖都会当",
    "场报错，而不是等到用户双击的时候才发现。",
    "",
    "本地推理，不上传任何文件。",
]


def build(dst: Path, dpi: int = 200) -> Path:
    #  1. 先做一张「带文字的纸」
    src = pymupdf.open()
    page = src.new_page(width=420, height=595)          # A5 竖
    font = pymupdf.Font("china-ss")
    tw = pymupdf.TextWriter(page.rect)
    y = 90.0
    for line in TEXT:
        if line:
            tw.append((60, y), line, font=font, fontsize=13)
        y += 26
    tw.write_text(page)

    #  2. 栅格化成位图 —— 这一步把文字层抹掉，得到真正的「扫描件」
    pix = page.get_pixmap(dpi=dpi)

    #  3. 位图贴成纯图像页
    out = pymupdf.open()
    p2 = out.new_page(width=420, height=595)
    p2.insert_image(p2.rect, pixmap=pix)
    dst.parent.mkdir(parents=True, exist_ok=True)
    out.save(str(dst), garbage=4, deflate=True)
    out.close()
    src.close()
    return dst


if __name__ == "__main__":
    target = Path(sys.argv[1] if len(sys.argv) > 1 else "probe.pdf")
    p = build(target)
    print(f"{p}  {p.stat().st_size:,} B")
