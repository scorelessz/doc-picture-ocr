#!/usr/bin/env python3
"""
单源条目的第三方仲裁 —— 用 Tesseract 只跑这些行。

背景: 交叉验证只在「两个引擎都出了结果」时有效。若某行只有一个引擎
      识别出内容(kind = only_*), 校对时就没有对照, 全靠肉眼比对原图。
      实测上半部分.pdf 有 52 条属于此类(32%), 抽验 4 条全部有残留错误。

为什么这里该用 Tesseract, 而通用场景不该:
      作为通用第三引擎时, 它会让复核量涨 6 倍(实测), 得不偿失。
      但单源条目**压根没有交叉验证**, 任何第二意见都是净增益,
      不存在「增加复核量」的问题。

做法: 只裁出这些行的图像区域, 用 --psm 7(单行模式)跑, 放大 2 倍
      以改善细笔画识别。结果与人工采纳稿比对, 只报分歧。

用法:
  .venv/bin/python src/arbitrate.py work/X.crosscheck.json fixes1.json [fixes2.json ...]
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
from normalize import norm, equiv

SCALE = 2.0
PAD = 6


def tess_line(img_path: Path, box, lang="chi_sim") -> str:
    """裁出一行, 放大后用单行模式跑 Tesseract。"""
    from PIL import Image
    x, y, w, h = box
    with Image.open(img_path) as im:
        x0 = max(0, int(x) - PAD); y0 = max(0, int(y) - PAD)
        x1 = min(im.width, int(x + w) + PAD); y1 = min(im.height, int(y + h) + PAD)
        if x1 <= x0 or y1 <= y0:
            return ""
        crop = im.crop((x0, y0, x1, y1)).convert("L")
        crop = crop.resize((int(crop.width * SCALE), int(crop.height * SCALE)),
                           Image.LANCZOS)
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tf:
            crop.save(tf.name)
            tmp = tf.name
    try:
        # 参数顺序要紧: configfile 必须在选项之后, 否则 -l/--psm 被静默忽略
        r = subprocess.run(
            ["tesseract", tmp, "stdout", "-l", lang, "--psm", "7"],
            capture_output=True, text=True,
        )
        return r.stdout.strip().replace("\n", "") if r.returncode == 0 else ""
    finally:
        Path(tmp).unlink(missing_ok=True)


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    cc = json.loads(Path(sys.argv[1]).read_text("utf-8"))
    ea, eb = cc["engines"]
    items = cc["items"]

    fixes: dict[int, str] = {}
    for fp in sys.argv[2:]:
        fixes.update({int(k): v for k, v in
                      json.loads(Path(fp).read_text("utf-8")).items()})

    single = [(i, it) for i, it in enumerate(items) if it["kind"] != "disagree"]
    print(f"单源条目 {len(single)} 条, 逐条用 Tesseract 仲裁...\n", file=sys.stderr)

    agree, differ, empty = 0, 0, 0
    out = []
    for n, (i, it) in enumerate(single, 1):
        accepted = fixes.get(i, "")
        if not accepted.strip():
            empty += 1
            continue
        t = tess_line(ROOT / it["image"], it["crop"])
        if not t:
            empty += 1
            continue
        if equiv(accepted, t):
            agree += 1
            continue
        differ += 1
        out.append({"i": i, "page": it["page"], "kind": it["kind"],
                    "accepted": accepted, "tesseract": t})
        if n % 10 == 0:
            print(f"  ...{n}/{len(single)}", file=sys.stderr)

    print(f"\n=== 仲裁结果 ===")
    print(f"  与采纳稿一致   {agree:>3} 条  (可信度提高)")
    print(f"  有分歧         {differ:>3} 条  (需要你看)")
    print(f"  Tesseract 无输出 {empty:>3} 条")

    res = ROOT / "work" / f"{Path(cc['source']).stem}.arbitrate.json"
    res.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"\n-> {res.relative_to(ROOT)}")

    print(f"\n=== 分歧明细 ===")
    print("Tesseract 精度低于另外两个, 它的读法**不可直接采信**;")
    print("它的价值只在于指出「这里可能有问题, 去看原图」。\n")
    for o in out:
        print(f"  #{o['i']:<4} p{o['page']:<3} [{o['kind']}]")
        print(f"     采纳: {o['accepted'][:58]}")
        print(f"     Tess: {o['tesseract'][:58]}")


if __name__ == "__main__":
    main()
