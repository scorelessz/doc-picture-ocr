#!/usr/bin/env python3
"""
阶段 2: RapidOCR (ONNX Runtime) -> 标准化 JSON

复用 run_vision.py 已抽出的页面图片(work/<stem>/pages/), 保证两个引擎
看到的是完全相同的像素, 坐标才能对齐。

输出格式与 run_vision.py 完全一致, 仅 engine 字段不同。
用法: .venv/bin/python src/run_rapidocr.py <pdf> [--out work/xxx.rapidocr.json]
"""
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMG_EXT = (".jpg", ".jpeg", ".png", ".ppm", ".pbm", ".tif")


def normalize(result) -> list[dict]:
    """把 RapidOCR 的返回归一成 [{x,y,w,h,conf,text}]。

    RapidOCR 3.x 返回对象(boxes/txts/scores); 老版本返回 [(box, text, score), ...]。
    两种都兼容。
    """
    boxes = txts = scores = None

    if hasattr(result, "boxes"):
        boxes, txts, scores = result.boxes, result.txts, result.scores
    elif isinstance(result, (list, tuple)) and result:
        first = result[0]
        if isinstance(first, (list, tuple)) and len(first) == 3:
            boxes = [r[0] for r in result]
            txts = [r[1] for r in result]
            scores = [r[2] for r in result]
        else:  # (result, elapse) 形式
            return normalize(first)

    if boxes is None or txts is None:
        return []

    lines = []
    for box, txt, score in zip(boxes, txts, scores):
        xs = [float(p[0]) for p in box]
        ys = [float(p[1]) for p in box]
        x0, x1 = min(xs), max(xs)
        y0, y1 = min(ys), max(ys)
        lines.append({
            "x": round(x0, 1), "y": round(y0, 1),
            "w": round(x1 - x0, 1), "h": round(y1 - y0, 1),
            "conf": round(float(score), 4),
            "text": str(txt),
        })
    # 阅读顺序: 上到下, 左到右
    lines.sort(key=lambda l: (round(l["y"] / 20), l["x"]))
    return lines


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    pdf = Path(sys.argv[1]).expanduser().resolve()
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv \
        else ROOT / "work" / f"{pdf.stem}.rapidocr.json"

    pagedir = ROOT / "work" / pdf.stem / "pages"
    imgs = sorted(p for p in pagedir.glob("pg-*") if p.suffix.lower() in IMG_EXT)
    if not imgs:
        raise SystemExit(f"找不到页面图片: {pagedir}\n请先跑 src/run_vision.py")

    from rapidocr import RapidOCR  # 延迟导入, 便于上面的报错先出
    print("初始化 RapidOCR (首次会下载模型)...", file=sys.stderr)
    t0 = time.time()
    engine = RapidOCR()
    print(f"  就绪 ({time.time()-t0:.1f}s)", file=sys.stderr)

    from PIL import Image  # rapidocr 依赖里带

    pages = []
    total = 0
    for i, img in enumerate(imgs, 1):
        t = time.time()
        result = engine(str(img))
        lines = normalize(result)
        with Image.open(img) as im:
            w, h = im.size
        chars = sum(len(l["text"]) for l in lines)
        total += chars
        pages.append({
            "page": i, "width": w, "height": h,
            "image": str(img.relative_to(ROOT)), "lines": lines,
        })
        print(f"  第{i}页 {w}x{h}  {len(lines)}行  {chars}字  ({time.time()-t:.1f}s)",
              file=sys.stderr)

    doc = {"source": str(pdf), "engine": "rapidocr", "pages": pages}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"-> {out.relative_to(ROOT)}  (共 {total} 字)", file=sys.stderr)


if __name__ == "__main__":
    main()
