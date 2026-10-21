#!/usr/bin/env python3
"""
阶段 1: PDF -> 页面图片 -> macOS Vision OCR -> 标准化 JSON

标准化输出格式(所有引擎共用, 供阶段 3 交叉比对):
{
  "source": "<pdf路径>",
  "engine": "vision",
  "pages": [
    {"page": 1, "width": 1880, "height": 2885, "image": "work/.../pg-000.jpg",
     "lines": [{"x":.., "y":.., "w":.., "h":.., "conf":.., "text":".."}]}
  ]
}

坐标系: 像素, 原点左上角。
用法: python3 src/run_vision.py <pdf> [--out work/vision.json]
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "bin" / "vision-ocr"
IMG_EXT = (".jpg", ".jpeg", ".png", ".ppm", ".pbm", ".tif")


def extract_pages(pdf: Path, workdir: Path) -> list[Path]:
    """用 pdfimages -j 抽取内嵌原图(无重编码, 不引入额外损失)。"""
    workdir.mkdir(parents=True, exist_ok=True)
    for stale in workdir.glob("pg-*"):
        stale.unlink()
    subprocess.run(
        ["pdfimages", "-j", str(pdf), str(workdir / "pg")],
        check=True, capture_output=True,
    )
    pages = sorted(p for p in workdir.glob("pg-*") if p.suffix.lower() in IMG_EXT)
    if not pages:
        raise SystemExit(f"未能从 {pdf} 抽出页面图像")
    return pages


def run_vision(img: Path) -> tuple[list[dict], int, int]:
    """调用编译好的 Vision 二进制, 解析 TSV。"""
    r = subprocess.run([str(BIN), str(img)], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"vision-ocr 失败 ({img.name}): {r.stderr.strip()}")

    w = h = 0
    m = re.search(r"image:\s*(\d+)x(\d+)", r.stderr)
    if m:
        w, h = int(m.group(1)), int(m.group(2))

    lines = []
    for ln in r.stdout.splitlines():
        parts = ln.split("\t")
        if len(parts) != 6:
            continue
        x, y, bw, bh, conf, text = parts
        lines.append({
            "x": round(float(x), 1), "y": round(float(y), 1),
            "w": round(float(bw), 1), "h": round(float(bh), 1),
            "conf": round(float(conf), 4), "text": text,
        })
    return lines, w, h


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    pdf = Path(sys.argv[1]).expanduser().resolve()
    if not pdf.exists():
        raise SystemExit(f"文件不存在: {pdf}")

    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv \
        else ROOT / "work" / f"{pdf.stem}.vision.json"
    out.parent.mkdir(parents=True, exist_ok=True)

    workdir = ROOT / "work" / pdf.stem / "pages"
    pages_img = extract_pages(pdf, workdir)
    print(f"抽出 {len(pages_img)} 页", file=sys.stderr)

    pages = []
    total_chars = 0
    for i, img in enumerate(pages_img, 1):
        lines, w, h = run_vision(img)
        chars = sum(len(l["text"]) for l in lines)
        total_chars += chars
        pages.append({
            "page": i, "width": w, "height": h,
            "image": str(img.relative_to(ROOT)),
            "lines": lines,
        })
        print(f"  第{i}页 {w}x{h}  {len(lines)}行  {chars}字", file=sys.stderr)

    doc = {"source": str(pdf), "engine": "vision", "pages": pages}
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"-> {out.relative_to(ROOT)}  (共 {total_chars} 字)", file=sys.stderr)


if __name__ == "__main__":
    main()
