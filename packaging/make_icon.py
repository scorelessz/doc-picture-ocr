#!/usr/bin/env python3
"""生成 packaging/AppIcon.icns。纯 PIL 绘制，不依赖任何素材文件。

build.sh 在 .icns 缺失时自动调用；已经有了就跳过（幂等）。
手动重做：.venv/bin/python packaging/make_icon.py --force

图形：一张扫描页（带文字行）+ 一个放大镜。刻意不用文字，避免字体依赖。
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
OUT = HERE / "AppIcon.icns"

#  macOS 圆角矩形图标的惯例：内容占 1024 画布的中间 824，四周留白
S = 1024
R = 180                      # 圆角半径
BG1 = (34, 46, 66)           # 深蓝底
BG2 = (18, 26, 40)
PAPER = (250, 250, 247)
INK = (58, 70, 92)
ACCENT = (255, 176, 59)      # 放大镜描边


def _rounded(size: int, radius: int, fill) -> Image.Image:
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(im).rounded_rectangle((0, 0, size - 1, size - 1),
                                         radius=radius, fill=fill)
    return im


def render() -> Image.Image:
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    #  底板：竖向渐变 + 圆角裁切
    grad = Image.new("RGBA", (1, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / (S - 1)
        gd.point((0, y), fill=tuple(int(a + (b - a) * t) for a, b in
                                    zip(BG1, BG2)) + (255,))
    grad = grad.resize((S, S))
    im.paste(grad, (0, 0), _rounded(S, R, (255, 255, 255, 255)))

    d = ImageDraw.Draw(im)

    #  纸张（略微倾斜的两张，暗示「一叠扫描件」）
    sheet = Image.new("RGBA", (470, 600), (0, 0, 0, 0))
    ImageDraw.Draw(sheet).rounded_rectangle((0, 0, 469, 599), radius=26,
                                            fill=(228, 230, 226, 255))
    im.alpha_composite(sheet.rotate(-7, expand=True,
                                    resample=Image.BICUBIC), (236, 196))

    front = Image.new("RGBA", (470, 600), (0, 0, 0, 0))
    fd = ImageDraw.Draw(front)
    fd.rounded_rectangle((0, 0, 469, 599), radius=26, fill=PAPER + (255,))
    #  文字行
    y = 86
    for i in range(9):
        w = 330 if i % 4 != 3 else 210
        fd.rounded_rectangle((70, y, 70 + w, y + 26), radius=13,
                             fill=INK + (255 if i else 255,))
        y += 56
    im.alpha_composite(front, (276, 212))

    #  放大镜
    cx, cy, rr, lw = 660, 672, 168, 42
    d.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), outline=ACCENT, width=lw)
    d.ellipse((cx - rr + lw // 2, cy - rr + lw // 2,
               cx + rr - lw // 2, cy + rr - lw // 2),
              fill=(255, 255, 255, 46))
    d.line((cx + 118, cy + 118, cx + 232, cy + 232), fill=ACCENT,
           width=lw + 8)
    d.ellipse((cx + 232 - (lw + 8) // 2, cy + 232 - (lw + 8) // 2,
               cx + 232 + (lw + 8) // 2, cy + 232 + (lw + 8) // 2),
              fill=ACCENT)
    return im


def build_icns(dst: Path) -> None:
    master = render()
    with tempfile.TemporaryDirectory() as td:
        iconset = Path(td) / "AppIcon.iconset"
        iconset.mkdir()
        for px in (16, 32, 128, 256, 512):
            master.resize((px, px), Image.LANCZOS).save(
                iconset / f"icon_{px}x{px}.png")
            master.resize((px * 2, px * 2), Image.LANCZOS).save(
                iconset / f"icon_{px}x{px}@2x.png")
        if shutil.which("iconutil"):
            subprocess.run(["iconutil", "-c", "icns", str(iconset),
                            "-o", str(dst)], check=True)
        else:                                   # 没有 iconutil 就退回 PNG
            master.save(dst.with_suffix(".png"))
            raise SystemExit("找不到 iconutil，只写出了 PNG")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--out", default=str(OUT))
    a = ap.parse_args()
    dst = Path(a.out)
    if dst.exists() and not a.force:
        print(f"已存在，跳过：{dst}")
        return 0
    build_icns(dst)
    print(f"写出 {dst}  {dst.stat().st_size:,} B")
    return 0


if __name__ == "__main__":
    sys.exit(main())
