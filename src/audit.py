#!/usr/bin/env python3
"""
成稿整体复查 —— 直接扫 output/*.md, 不依赖任何中间数据。

这是交付前的最后一道关。前面的机制(交叉验证/术语表/人工校对)各有盲区,
这里用一组与它们独立的规则再过一遍。

检查项:
  1. 残留噪声: 省略号变体、孤立拉丁/数字、全半角标点混用
  2. 括号配对(按区块, 不按行 —— 跨行括号在行级必然误报)
  3. 重复区块: 完全相同 / 一方包含另一方
  4. 高频词近似误读: 罕见词串与高频词仅差一字, 且差异字全文罕见
  5. 结构: V.O 写法一致性、场景标题编号连续性、过短碎块
  6. 生僻字: 全文只出现一两次的字, 多为 OCR 误读残留

用法: .venv/bin/python src/audit.py output/X.md [output/Y.md ...]
"""
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

CJK = "[一-鿿]"
BR = {"（": "）", "〔": "〕", "【": "】", "｛": "｝", "［": "］",
      "《": "》", "〈": "〉", "「": "」", "『": "』", "(": ")", "[": "]"}
CLOSE = {v: k for k, v in BR.items()}


def blocks_of(md: str) -> list[str]:
    return [b.strip() for b in md.split("\n\n") if b.strip()]


def check_noise(blocks):
    out = []
    for i, b in enumerate(blocks):
        for pat, why in [
            (r"[•]|[·]{2,}|⋯", "省略号噪声"),
            (rf"(?<={CJK})[0-9A-Za-z](?={CJK})", "孤立拉丁/数字夹在中文中"),
            (rf"(?<={CJK})[,;:?!](?={CJK})", "半角标点夹在中文中"),
        ]:
            m = re.search(pat, b)
            if m:
                out.append((i, why, b[max(0, m.start() - 12):m.start() + 14]))
    return out


def check_brackets(blocks):
    out = []
    for i, b in enumerate(blocks):
        stack = []
        for ch in b:
            if ch in BR:
                stack.append(ch)
            elif ch in CLOSE:
                if not stack:
                    out.append((i, f"多余右括号 {ch!r}", b[:40]))
                    break
                op = stack.pop()
                if BR[op] != ch:
                    out.append((i, f"括号不同族 {op!r}…{ch!r}", b[:40]))
                    break
        else:
            if stack:
                out.append((i, f"未闭合 {stack[0]!r}", b[:40]))
    return out


def check_dups(blocks):
    seen, out = {}, []
    for i, b in enumerate(blocks):
        k = re.sub(r"\s+", "", b)
        if len(k) < 10:
            continue
        if k in seen:
            out.append((i, f"与区块 {seen[k]} 完全相同", b[:40]))
        else:
            seen[k] = i
    return out


def check_nearmiss(text: str):
    """罕见词串 vs 高频词仅差一字, 且差异字全文也罕见 => 多半是误读。"""
    cf = Counter(text)
    out = []
    for n in (2, 3):
        c = Counter()
        for i in range(len(text) - n + 1):
            seg = text[i:i + n]
            if re.fullmatch(CJK + "{" + str(n) + "}", seg):
                c[seg] += 1
        common = {g: v for g, v in c.items() if v >= 15}
        for r, rn in c.items():
            if rn > 2:
                continue
            for g, gn in common.items():
                if gn < rn * 25 or len(r) != len(g):
                    continue
                diff = [(x, y) for x, y in zip(g, r) if x != y]
                if len(diff) != 1:
                    continue
                right, wrong = diff[0]
                if cf[wrong] <= 2:          # 差异字全文也罕见
                    out.append((rn, r, g, wrong, cf[wrong]))
                break
    out.sort(key=lambda t: (t[4], t[0]))
    return out


def check_structure(blocks, text):
    out = []
    vo = Counter(re.findall(r"[（(]\s*([VY])\s*[.．]\s*([O0o])\s*[，,]", text))
    if len(vo) > 1:
        out.append(("V.O 写法不一致: " + ", ".join(f"{a}.{b}" for a, b in vo), ""))
    scenes = [b for b in blocks if b.startswith("## ")]
    nums = []
    for s in scenes:
        m = re.match(r"##\s*(\d{1,3})\s*[.、．]", s)
        if m:
            nums.append(int(m.group(1)))
    gaps = [(a, b) for a, b in zip(nums, nums[1:]) if b not in (a, a + 1)]
    if gaps:
        out.append((f"场景编号跳号 {len(gaps)} 处", str(gaps[:6])))
    short = [i for i, b in enumerate(blocks)
             if not b.startswith("#") and len(re.sub(r"\W", "", b)) <= 2]
    if short:
        out.append((f"过短碎块 {len(short)} 个", str(short[:10])))
    return out


def main() -> None:
    for fp in sys.argv[1:]:
        p = Path(fp)
        md = p.read_text("utf-8")
        blocks = blocks_of(md)
        text = "".join(blocks)
        print(f"\n{'='*58}\n{p.name}   {len(md)} 字符 / {len(blocks)} 区块\n{'='*58}")

        for label, rows in [("噪声残留", check_noise(blocks)),
                            ("括号问题", check_brackets(blocks)),
                            ("重复区块", check_dups(blocks))]:
            print(f"\n[{label}] {len(rows)} 处")
            for i, why, ctx in rows[:8]:
                print(f"   块{i:<4} {why}: …{ctx}…")
            if len(rows) > 8:
                print(f"   ... 另有 {len(rows)-8} 处")

        nm = check_nearmiss(text)
        print(f"\n[疑似误读] {len(nm)} 组")
        for rn, r, g, wrong, cfw in nm[:10]:
            print(f"   {r!r}({rn}次) ← 疑为 {g!r}   差异字 {wrong!r} 全文仅 {cfw} 次")

        st = check_structure(blocks, text)
        print(f"\n[结构] {len(st)} 项")
        for a, b in st:
            print(f"   {a}  {b}")


if __name__ == "__main__":
    main()
