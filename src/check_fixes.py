#!/usr/bin/env python3
"""
回填前的校对结果核对 —— 在把人工校对写进正稿之前, 先验一遍。

检查项:
  1. 覆盖率: 是否每条可疑项都有结论
  2. 来源: 是照抄某个引擎, 还是人工改过(改过的可信度更高)
  3. 残留可疑: 省略号噪声、行首标记误读、场景标题编号异常、
              空条目、仅标记条目、疑似截断
  4. 重复: 多个条目给出完全相同的文本(可能是重复条目, 也可能是误操作)

用法: .venv/bin/python src/check_fixes.py work/X.crosscheck.json fixes1.json [fixes2.json ...]
"""
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
from normalize import norm, equiv

# 仍然可疑的模式
# 三处曾经的误报, 已剔除(都是实测撞上的):
#   * 「以逗号结尾」—— 审校单位是**行**不是段, 长句跨行本来就以逗号收尾
#   * 单个 `·`     —— 《归潮·家己人》《颂西·坦西里坤》里是合法间隔号
#   * 「字母编号」 —— 本剧本数字编号做主场景、字母编号做蒙太奇子场景,
#                    A. / D. 是原件就有的, 不是 OCR 误读
SUSPECT = [
    (re.compile(r"[•]|[·]{2,}"), "省略号噪声(•)"),
    (re.compile(r"⋯"), "省略号变体(⋯)"),
    (re.compile(r"^\s*[AＡ厶二ム]\s+[一-鿿]"), "行首标记疑似被读成字母/汉字"),
    (re.compile(r"[一-鿿][0-9]{1,2}[一-鿿]"), "中文夹孤立数字"),
]


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    cc = json.loads(Path(sys.argv[1]).read_text("utf-8"))
    ea, eb = cc["engines"]
    items = cc["items"]

    fixes: dict[int, str] = {}
    collide = []
    for fp in sys.argv[2:]:
        d = json.loads(Path(fp).read_text("utf-8"))
        for k, v in d.items():
            ik = int(k)
            if ik in fixes and fixes[ik] != v:
                collide.append(ik)
            fixes[ik] = v
        print(f"读入 {Path(fp).name}: {len(d)} 条")

    print(f"\n合计 {len(fixes)} 条 / 可疑项 {len(items)} 条")
    if collide:
        print(f"  ⚠ {len(collide)} 条在两份文件里给了不同结论: {collide[:10]}")

    # --- 1. 覆盖率 ---
    missing = [i for i in range(len(items)) if i not in fixes]
    if missing:
        print(f"  ⚠ 未处理 {len(missing)} 条: {missing[:20]}")
    else:
        print("  ✅ 覆盖完整")

    # --- 2. 来源分布 ---
    src = Counter()
    manual: list[int] = []
    for i, it in enumerate(items):
        if i not in fixes:
            continue
        f = fixes[i]
        a, b = it.get(ea, ""), it.get(eb, "")
        if f == a:
            src["照抄 " + ea] += 1
        elif f == b:
            src["照抄 " + eb] += 1
        elif not f.strip():
            src["清空"] += 1
        else:
            src["人工改写"] += 1
            manual.append(i)
    print("\n=== 结论来源 ===")
    for k, v in src.most_common():
        print(f"  {k:<16} {v:>4} 条")

    # --- 3. 残留可疑 ---
    flags: dict[int, list[str]] = defaultdict(list)
    for i, f in fixes.items():
        t = f.strip()
        if not t:
            flags[i].append("空(该行将被删除)")
            continue
        if re.fullmatch(r"[△▲AＡ\s]+", t):
            flags[i].append("仅剩标记, 无正文")
            continue
        if re.fullmatch(r"\d{1,3}", t):
            flags[i].append("纯数字, 疑似页码被当成正文")
        for pat, why in SUSPECT:
            if pat.search(t):
                flags[i].append(why)

    print(f"\n=== 仍需留意 ({len(flags)} 条) ===")
    for i in sorted(flags):
        why = "; ".join(sorted(set(flags[i])))
        pg = items[i]["page"] if i < len(items) else "?"
        print(f"  #{i:<4} p{pg:<3} [{why}]")
        print(f"        {fixes[i][:60]}")

    # --- 4. 重复文本 ---
    rev: dict[str, list[int]] = defaultdict(list)
    for i, f in fixes.items():
        if f.strip():
            rev[norm(f)].append(i)
    dups = {k: v for k, v in rev.items() if len(v) > 1}
    if dups:
        print(f"\n=== 文本重复 ({len(dups)} 组) ===")
        print("  同一句被多个条目采用 —— 多为 OCR 把同一行切成两条, 属正常;")
        print("  但若两条指向不同页, 需要确认是不是误操作。")
        for k, v in list(dups.items())[:12]:
            pages = sorted({items[i]["page"] for i in v if i < len(items)})
            mark = "  ⚠跨页" if len(pages) > 1 else ""
            print(f"  {v} p{pages}{mark}  {k[:44]}")


if __name__ == "__main__":
    main()
