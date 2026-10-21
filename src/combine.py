#!/usr/bin/env python3
"""
把分段成稿合并成一个完整 Markdown。

分段只是扫描时的物理切分, 不是剧本结构。合并时:
  * 去掉各分段由文件名生成的 H1(# 上半部分 之类)
  * 用剧本本身的标题做唯一 H1
  * 校验接缝: 场景编号必须连续、不重叠

用法: .venv/bin/python src/combine.py 上半部分 中间部分 下半部分 --out output/全片.md
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCENE = re.compile(r"^##\s*(\d{1,3})\s*[.、．]")


def main() -> None:
    # 注意跳过带值选项的**值**, 否则它会被当成分段名
    argv, parts, skip = sys.argv[1:], [], False
    for i, a in enumerate(argv):
        if skip:
            skip = False
            continue
        if a in ("--out", "--title"):
            skip = True
            continue
        if not a.startswith("--"):
            parts.append(a)
    out = Path(argv[argv.index("--out") + 1]) if "--out" in argv \
        else ROOT / "output" / "全片.md"
    title = argv[argv.index("--title") + 1] if "--title" in argv else None

    all_blocks: list[str] = []
    seams = []
    for name in parts:
        p = ROOT / "output" / f"{name}.md"
        blocks = [b.strip() for b in p.read_text("utf-8").split("\n\n") if b.strip()]
        # 丢掉文件名生成的 H1
        blocks = [b for b in blocks if not re.fullmatch(rf"#\s*{re.escape(name)}", b)]
        # 首段若是剧本标题, 提升为全片 H1
        if title is None and blocks and re.fullmatch(r"《.+》.*", blocks[0]):
            title = blocks[0]        # 原样用剧本自己的标题
            blocks = blocks[1:]
        nums = [int(m.group(1)) for b in blocks if (m := SCENE.match(b))]
        seams.append((name, len(blocks), min(nums) if nums else None,
                      max(nums) if nums else None))
        all_blocks += blocks

    md = f"# {title or out.stem}\n\n" + "\n\n".join(all_blocks) + "\n"
    md = re.sub(r"\n{3,}", "\n\n", md)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(md, encoding="utf-8")

    print(f"标题: {title}")
    for name, n, lo, hi in seams:
        print(f"  {name:<8} {n:>4} 区块   场景 {lo}-{hi}")

    # 接缝校验
    nums = [int(m.group(1)) for b in all_blocks if (m := SCENE.match(b))]
    uniq = sorted(set(nums))
    miss = [i for i in range(uniq[0], uniq[-1] + 1) if i not in uniq]
    dup = sorted({x for x in nums if nums.count(x) > 1})
    print(f"\n场景编号 {uniq[0]}-{uniq[-1]}   缺失: {miss or '无'}   重复: {dup or '无'}")
    for (a, _, _, ahi), (b, _, blo, _) in zip(seams, seams[1:]):
        flag = "✅" if blo == ahi + 1 or blo == ahi else "⚠"
        print(f"  {flag} {a} 末场 {ahi} → {b} 首场 {blo}")
    try:
        shown = out.resolve().relative_to(ROOT)
    except ValueError:
        shown = out
    print(f"\n-> {shown}   {len(md)} 字符 / {len(all_blocks)} 区块")


if __name__ == "__main__":
    main()
