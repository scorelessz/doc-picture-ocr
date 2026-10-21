#!/usr/bin/env python3
"""
把若干条目的行图像拼成一张「接触印像」大图, 便于一次性肉眼核对多行。

用途: 单源条目(无交叉验证)只能靠比对原图确认。逐条裁图看太慢,
      拼成一张带编号的长图, 一次看十几条。

用法:
  .venv/bin/python src/contactsheet.py work/X.crosscheck.json out.png \\
      --ids 21,24,26,39 [--scale 1.4]
  .venv/bin/python src/contactsheet.py work/X.crosscheck.json out.png \\
      --kind single --start 0 --count 12
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAD = 8
GAP = 10
LABEL_W = 92


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    from PIL import Image, ImageDraw

    cc = json.loads(Path(sys.argv[1]).read_text("utf-8"))
    out = Path(sys.argv[2])
    items = cc["items"]
    scale = float(sys.argv[sys.argv.index("--scale") + 1]) \
        if "--scale" in sys.argv else 1.0

    if "--ids" in sys.argv:
        ids = [int(x) for x in sys.argv[sys.argv.index("--ids") + 1].split(",")]
    else:
        pool = [i for i, it in enumerate(items) if it["kind"] != "disagree"] \
            if "--kind" in sys.argv and sys.argv[sys.argv.index("--kind") + 1] == "single" \
            else list(range(len(items)))
        st = int(sys.argv[sys.argv.index("--start") + 1]) if "--start" in sys.argv else 0
        ct = int(sys.argv[sys.argv.index("--count") + 1]) if "--count" in sys.argv else 12
        ids = pool[st:st + ct]

    crops = []
    for i in ids:
        it = items[i]
        x, y, w, h = it["crop"]
        with Image.open(ROOT / it["image"]) as im:
            x0 = max(0, int(x) - PAD); y0 = max(0, int(y) - PAD)
            x1 = min(im.width, int(x + w) + PAD); y1 = min(im.height, int(y + h) + PAD)
            if x1 <= x0 or y1 <= y0:
                continue
            c = im.crop((x0, y0, x1, y1)).convert("L")
        if scale != 1.0:
            c = c.resize((int(c.width * scale), int(c.height * scale)), Image.LANCZOS)
        crops.append((i, it["page"], c))

    if not crops:
        raise SystemExit("没有可拼的条目")

    W = LABEL_W + max(c.width for _, _, c in crops) + PAD
    H = sum(c.height for _, _, c in crops) + GAP * (len(crops) + 1)
    sheet = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(sheet)

    yy = GAP
    for i, pg, c in crops:
        sheet.paste(c, (LABEL_W, yy))
        d.text((6, yy + c.height // 2 - 6), f"#{i}  p{pg}", fill=0)
        d.line([(0, yy - GAP // 2), (W, yy - GAP // 2)], fill=200)
        yy += c.height + GAP

    sheet.save(out)
    print(f"{out}  {W}x{H}  共 {len(crops)} 条: {[i for i,_,_ in crops]}")


if __name__ == "__main__":
    main()
