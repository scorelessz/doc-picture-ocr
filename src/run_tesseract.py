#!/usr/bin/env python3
"""
第三引擎: Tesseract (LSTM) -> 标准化 JSON

定位与前两个引擎不同 —— 它精度更低, 不作为「投票者」, 而是作为
**架构独立的标记器**:

  Vision 和 PP-OCRv6 都是在相似中文语料上训练的, 遇到真正模糊的字形
  会一起错(相关性错误), 交叉验证对此无能为力。
  Tesseract 架构与训练语料都不同, 它的分歧有机会指出这类盲区。

代价是误报率高(它本身错得多), 所以它的分歧单独成列, 优先级低于
Vision↔PP-OCRv6 的分歧。

用法: .venv/bin/python src/run_tesseract.py <pdf> [--psm 3] [--lang chi_sim]
"""
import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMG_EXT = (".jpg", ".jpeg", ".png", ".ppm", ".pbm", ".tif")


def tesseract_lines(img: Path, lang: str, psm: str) -> list[dict]:
    """跑 tesseract 的 TSV 输出, 按 (block,par,line) 聚合成行。"""
    # 参数顺序要紧: tesseract <img> <outbase> [options...] [configfile...]
    # configfile(tsv) 必须在所有选项之后, 否则 -l/--psm 会被忽略。
    r = subprocess.run(
        ["tesseract", str(img), "stdout", "-l", lang, "--psm", psm, "tsv"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise SystemExit(f"tesseract 失败: {r.stderr.strip()[:300]}")

    rows = r.stdout.splitlines()
    if not rows:
        return []
    header = rows[0].split("\t")
    idx = {name: i for i, name in enumerate(header)}

    groups: dict[tuple, list] = defaultdict(list)
    for row in rows[1:]:
        f = row.split("\t")
        if len(f) < len(header):
            continue
        try:
            level = int(f[idx["level"]])
        except ValueError:
            continue
        if level != 5:                      # 5 = word
            continue
        text = f[idx["text"]].strip()
        if not text:
            continue
        try:
            conf = float(f[idx["conf"]])
        except ValueError:
            conf = -1.0
        if conf < 0:
            continue
        key = (f[idx["block_num"]], f[idx["par_num"]], f[idx["line_num"]])
        groups[key].append({
            "l": int(f[idx["left"]]), "t": int(f[idx["top"]]),
            "w": int(f[idx["width"]]), "h": int(f[idx["height"]]),
            "conf": conf, "text": text,
        })

    lines = []
    for words in groups.values():
        if not words:
            continue
        x0 = min(w["l"] for w in words)
        y0 = min(w["t"] for w in words)
        x1 = max(w["l"] + w["w"] for w in words)
        y1 = max(w["t"] + w["h"] for w in words)
        # 中文不加空格; tesseract 的 word 切分在中文里多为字/词块
        txt = "".join(w["text"] for w in sorted(words, key=lambda w: w["l"]))
        avg = sum(w["conf"] for w in words) / len(words) / 100.0
        lines.append({
            "x": float(x0), "y": float(y0),
            "w": float(x1 - x0), "h": float(y1 - y0),
            "conf": round(avg, 4), "text": txt,
        })
    lines.sort(key=lambda l: (round(l["y"] / 20), l["x"]))
    return lines


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    pdf = Path(sys.argv[1]).expanduser().resolve()
    lang = sys.argv[sys.argv.index("--lang") + 1] if "--lang" in sys.argv else "chi_sim"
    psm = sys.argv[sys.argv.index("--psm") + 1] if "--psm" in sys.argv else "3"
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv \
        else ROOT / "work" / f"{pdf.stem}.tesseract.json"

    pagedir = ROOT / "work" / pdf.stem / "pages"
    imgs = sorted(p for p in pagedir.glob("pg-*") if p.suffix.lower() in IMG_EXT)
    if not imgs:
        raise SystemExit(f"找不到页面图片: {pagedir}\n请先跑 src/run_vision.py")

    from PIL import Image

    pages, total = [], 0
    for i, img in enumerate(imgs, 1):
        lines = tesseract_lines(img, lang, psm)
        with Image.open(img) as im:
            w, h = im.size
        chars = sum(len(l["text"]) for l in lines)
        total += chars
        pages.append({"page": i, "width": w, "height": h,
                      "image": str(img.relative_to(ROOT)), "lines": lines})
        print(f"  第{i}页 {w}x{h}  {len(lines)}行  {chars}字", file=sys.stderr)

    doc = {"source": str(pdf), "engine": "tesseract",
           "config": {"lang": lang, "psm": psm}, "pages": pages}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"-> {out.relative_to(ROOT)}  (共 {total} 字, lang={lang} psm={psm})",
          file=sys.stderr)


if __name__ == "__main__":
    main()
