#!/usr/bin/env python3
"""语言学异常检测 + 术语表替换。供 book_fuse / run_books 调用。"""
import re
import sys
from pathlib import Path

CJK = r"一-鿿"
# 成对括号家族: 同一行内开闭应同族
BRACKET_PAIRS = {
    "（": "）", "〔": "〕", "【": "】", "｛": "｝", "［": "］",
    "《": "》", "〈": "〉", "「": "」", "『": "』", "(": ")", "[": "]", "{": "}",
}
CLOSERS = {v: k for k, v in BRACKET_PAIRS.items()}


# ---------- 语言学异常检测 ----------

def detect_anomalies(text: str) -> list[str]:
    """行级规则: 只放不受断行影响的检查。"""
    flags = []

    # (a) 孤立的单个数字/字母夹在中文之间 —— 如「一1道」
    #     多字符 token 不报(1994年、2G网络 是合法的)
    for m in re.finditer(rf"(?<=[{CJK}])([0-9A-Za-z])(?=[{CJK}])", text):
        flags.append(f"孤立字符 {m.group(1)!r} 夹在中文中 (位置 {m.start()})")

    # (b) 同一行内的括号跨家族混用 —— 如「【…）」
    #     只在行内成对时才判族, 不报「未闭合/多余」(那需要页级上下文)
    stack = []
    for i, ch in enumerate(text):
        if ch in BRACKET_PAIRS:
            stack.append((ch, i))
        elif ch in CLOSERS and stack:
            op, oi = stack.pop()
            if BRACKET_PAIRS[op] != ch:
                flags.append(f"括号不同族: {op!r}…{ch!r} (位置 {oi}-{i})")

    # (c) 中文里混入半角标点
    for m in re.finditer(rf"(?<=[{CJK}])([,;:?!])(?=[{CJK}])", text):
        flags.append(f"半角标点 {m.group(1)!r} 夹在中文中 (位置 {m.start()})")

    return flags


# ---------- 术语表 ----------

def load_glossary(path: Path) -> list[tuple[str, str]]:
    """格式(每行一条, # 开头为注释):
        正确词 <- 错误变体1, 错误变体2
    """
    rules = []
    if not path.exists():
        return rules
    for raw in path.read_text("utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or "<-" not in line:
            continue
        right, wrongs = line.split("<-", 1)
        right = right.strip()
        for w in wrongs.split(","):
            w = w.strip()
            if not w or w == right:
                continue
            # 防护: 单字符替换源会造成全文灾难性替换。
            # 实测踩过 —— 变体里写了含逗号的 "0,S", 被逗号分隔规则拆成
            # 单独的 "0" "S" 两条, 于是全文每个 S/0 都被替换掉了。
            # 变体本身不能包含逗号; 需要含逗号的变体请另起一行。
            if len(w) < 2:
                print(f"  [跳过] 术语表替换源过短, 风险太大: {w!r} -> {right!r}",
                      file=sys.stderr)
                continue
            rules.append((w, right))
    # 长的先replace, 避免短串抢先
    rules.sort(key=lambda r: -len(r[0]))
    return rules


def apply_glossary(text: str, rules: list[tuple[str, str]]) -> tuple[str, int]:
    n = 0
    for wrong, right in rules:
        if wrong in text:
            n += text.count(wrong)
            text = text.replace(wrong, right)
    return text, n
