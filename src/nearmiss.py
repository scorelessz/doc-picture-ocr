#!/usr/bin/env python3
"""
高频词近似误读检测 —— 针对「单源条目」这个交叉验证的盲区。

原理: 专有名词在剧本里会出现几百次。如果某个词串只出现 1~2 次, 而它与
      一个高频词仅差一个字, 那它几乎必然是 OCR 误读, 而不是真有这个词。

实测背景: 上半部分.pdf 有 52 条(32%)属于「单源」—— 另一引擎整行未出结果,
          校对时没有第二个候选可对照。抽验 4 条全部有残留错误, 且错的
          几乎都是「阿楠」这类高频人名(网楠 / 2间楠 / 阿稿 / 啊公)。

用法:
  .venv/bin/python src/nearmiss.py work/X.<engine>.json [--min-ratio 20] [--emit]
  --emit 直接输出可粘进 config/glossary.txt 的规则
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CJK = "[一-鿿]"


def edit1(a: str, b: str) -> bool:
    """是否恰好相差一个字符的替换(等长)。只认替换, 不认增删 ——
    增删会把「阿楠」和「阿楠家」这类真实派生词也卷进来。"""
    if len(a) != len(b):
        return False
    diff = sum(1 for x, y in zip(a, b) if x != y)
    return diff == 1


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    doc = json.loads(Path(sys.argv[1]).read_text("utf-8"))
    ratio = int(sys.argv[sys.argv.index("--min-ratio") + 1]) \
        if "--min-ratio" in sys.argv else 20

    text = "".join(l["text"] for p in doc["pages"] for l in p["lines"])

    # 统计 2~4 字的中文词串(滑窗, 允许重叠)
    grams: list[Counter] = []
    for n in (2, 3, 4):
        c = Counter()
        for i in range(len(text) - n + 1):
            seg = text[i:i + n]
            if re.fullmatch(CJK + "{" + str(n) + "}", seg):
                c[seg] += 1
        grams.append(c)

    # 单字频次: 用来判别「OCR 误读」还是「另一个相似的真词」。
    # 实测发现纯编辑距离噪声很大 —— 阿嬤/阿姨/潮剧/太公/广汕 都是真词,
    # 也都与高频词差一个字。但被替换进去的那个字如果全文几乎不出现
    # (网/稿), 就几乎必然是误读; 若本身常见(姨/剧), 多半是真词。
    charfreq = Counter(text)

    hits = []
    for c in grams:
        common = {g: n for g, n in c.items() if n >= 10}
        rare = {g: n for g, n in c.items() if n <= 2}
        for r, rn in rare.items():
            for g, gn in common.items():
                if gn < rn * ratio or not edit1(r, g):
                    continue
                # 找出差异位上的那个字, 取它的全文频次
                odd = next(y for x, y in zip(g, r) if x != y)
                hits.append((charfreq[odd], gn / rn, g, gn, r, rn, odd))
                break

    # 差异字越罕见越可疑, 排前面
    hits.sort(key=lambda h: (h[0], -h[1]))
    # 去重: 短串被长串包含且判定相同的, 只留长的
    seen: set[str] = set()
    kept = []
    for h in hits:
        if any(h[4] in s for s in seen):
            continue
        seen.add(h[4])
        kept.append(h)

    print(f"=== 高频词近似误读 (倍率 >= {ratio}) ===")
    print("按「差异字全文频次」升序 —— 越靠前越可能是 OCR 误读,")
    print("越靠后越可能只是另一个相似的真词(阿姨/潮剧/太公 之类)。\n")
    print(f"{'差异字频':>8}  {'疑似正确':<9}{'次数':>5}   {'疑似误读':<9}{'次数':>5}")
    for cf, f, g, gn, r, rn, odd in kept:
        bar = "★" if cf <= 3 else (" " if cf <= 12 else "·")
        print(f"{bar}{cf:>7}  {g:<11}{gn:>4}   {r:<11}{rn:>4}   (差异字 {odd!r})")
    print(f"\n共 {len(kept)} 组   ★ = 差异字全文 <=3 次, 高度可疑")

    if "--emit" in sys.argv:
        print("\n# --- 粘进 config/glossary.txt ---")
        byright: dict[str, list[str]] = {}
        for cf, _, g, _, r, _, _ in kept:
            if cf <= 3:
                byright.setdefault(g, []).append(r)
        for g, rs in byright.items():
            print(f"{g} <- {', '.join(rs)}")


if __name__ == "__main__":
    main()
