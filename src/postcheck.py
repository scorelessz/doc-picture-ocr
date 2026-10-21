#!/usr/bin/env python3
"""
阶段 4: 术语表校正 + 语言学异常检测

补交叉验证的短板 —— 「两个引擎一起错」的相关性错误。
两种机制互补:
  交叉验证  -> 字形层面的分歧
  本模块    -> 上下文上不可能的读法(两引擎可能一起错)

三个功能, 全部与具体文档无关:
  1. 术语候选自动提取: 从跨引擎分歧中挖出系统性误读(同一组错误反复出现)
  2. 语言学异常检测:   孤立数字/字母、括号不配对、标点混用、低置信
  3. 术语表强制校正:   按用户确认的术语表修正文本

用法:
  # 提取候选 + 检测异常(不改动文本)
  .venv/bin/python src/postcheck.py work/X.crosscheck.json

  # 带术语表, 输出校正后文本
  .venv/bin/python src/postcheck.py work/X.crosscheck.json \
      --glossary config/glossary.txt --engine rapidocr --apply
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from normalize import equiv

ROOT = Path(__file__).resolve().parent.parent

CJK = r"一-鿿"
# 成对括号家族: 同一行内开闭应同族
BRACKET_PAIRS = {
    "（": "）", "〔": "〕", "【": "】", "｛": "｝", "［": "］",
    "《": "》", "〈": "〉", "「": "」", "『": "』", "(": ")", "[": "]", "{": "}",
}
CLOSERS = {v: k for k, v in BRACKET_PAIRS.items()}


def rel(p: Path) -> str:
    """尽量显示成相对 ROOT 的路径, 不在 ROOT 下就原样显示。"""
    try:
        return str(Path(p).resolve().relative_to(ROOT))
    except ValueError:
        return str(p)


# ---------- 1. 术语候选自动提取 ----------

def glossary_candidates(items: list[dict], engines: list[str],
                        min_count: int = 2) -> list[dict]:
    """同一组(A读法, B读法)反复出现 => 系统性误读 => 术语表候选。

    这是通用机制: 不预设任何人名/术语, 纯粹靠「重复」这个统计信号。
    """
    ea, eb = engines
    pair_ctx = {}
    for it in items:
        for s in it.get("spans", []):
            a, b = s["a"].strip(), s["b"].strip()
            if not a or not b or a == b:
                continue
            # 已被归一化视为等价的(省略号变体、△ 标记读法)不是术语问题,
            # 不该占用人工确认的注意力
            if equiv(a, b):
                continue
            # 只关注短片段(字词级), 长片段多半是断行差异
            if len(a) > 6 or len(b) > 6:
                continue
            key = (a, b)
            pair_ctx.setdefault(key, []).append(it["page"])

    out = []
    for (a, b), pages in pair_ctx.items():
        if len(pages) < min_count:
            continue
        out.append({
            ea: a, eb: b, "count": len(pages),
            "pages": sorted(set(pages)),
        })
    out.sort(key=lambda d: -d["count"])
    return out


# ---------- 2. 语言学异常检测 ----------

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


def detect_page_anomalies(lines: list[str]) -> list[str]:
    """页级规则: 括号闭合必须跨行看, 否则跨行的《…》必然误报。"""
    text = "".join(lines)
    flags, stack = [], []
    for i, ch in enumerate(text):
        if ch in BRACKET_PAIRS:
            stack.append((ch, i))
        elif ch in CLOSERS:
            if not stack:
                flags.append(f"多余的右括号 {ch!r}")
            else:
                stack.pop()
    for op, _ in stack:
        flags.append(f"未闭合的左括号 {op!r}")
    return flags


def frequent_ngrams(lines: list[str], n_range=(2, 5), min_count: int = 3,
                    top: int = 30) -> list[tuple[str, int]]:
    """高频中文 n-gram —— 用于人工识别「两引擎一起错」的专有名词。

    这类词因为两个引擎输出一致, 不产生跨引擎分歧, 所以候选提取抓不到。
    但专有名词必然高频复现, 人一眼就能认出哪个是错的。
    """
    text = "".join(lines)
    ctr = Counter()
    for n in range(n_range[0], n_range[1] + 1):
        for m in re.finditer(rf"[{CJK}]{{{n}}}", text):
            ctr[m.group()] += 1
        # 滑窗(上面的 finditer 不重叠, 补一次重叠扫描)
        for i in range(len(text) - n + 1):
            seg = text[i:i + n]
            if re.fullmatch(rf"[{CJK}]{{{n}}}", seg):
                ctr[seg] += 1
    # 去掉被更长高频串完全包含且计数相近的短串
    items = [(s, c) for s, c in ctr.items() if c >= min_count]
    items.sort(key=lambda t: (-t[1], -len(t[0])))
    kept = []
    for s, c in items:
        if any(s in k and c <= kc * 1.2 for k, kc in kept):
            continue
        kept.append((s, c))
        if len(kept) >= top:
            break
    return kept


# ---------- 3. 术语表强制校正 ----------

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


# ---------- 主流程 ----------

def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cc = json.loads(Path(sys.argv[1]).read_text("utf-8"))
    engines = cc["engines"]
    items = cc["items"]

    gpath = Path(sys.argv[sys.argv.index("--glossary") + 1]).resolve() \
        if "--glossary" in sys.argv else ROOT / "config" / "glossary.txt"
    rules = load_glossary(gpath)

    # --- 1. 术语候选 ---
    cands = glossary_candidates(items, engines)
    print(f"=== 术语表候选 (系统性误读, 出现 >= 2 次) ===")
    if cands:
        ea, eb = engines
        print(f"{'次数':>4}  {ea:<12} {eb:<12} 页码")
        for c in cands[:25]:
            print(f"{c['count']:>4}  {c[ea]:<12} {c[eb]:<12} {c['pages']}")
        print(f"\n  -> 确认后写入 {rel(gpath)}，格式: 正确词 <- 错误变体")
    else:
        print("  (无重复出现的系统性误读)")

    # --- 2. 异常检测 ---
    src_engine = sys.argv[sys.argv.index("--engine") + 1] \
        if "--engine" in sys.argv else engines[-1]
    doc_path = ROOT / "work" / f"{Path(cc['source']).stem}.{src_engine}.json"
    if not doc_path.exists():
        raise SystemExit(f"\n找不到 {doc_path}")
    doc = json.loads(doc_path.read_text("utf-8"))

    print(f"\n=== 语言学异常 (引擎: {src_engine}) ===")
    total_anom = 0
    for page in doc["pages"]:
        texts = [l["text"] for l in page["lines"]]
        for li, t in enumerate(texts):
            for f in detect_anomalies(t):
                total_anom += 1
                if total_anom <= 20:
                    print(f"  p{page['page']} 行{li+1}: {f}")
        for f in detect_page_anomalies(texts):      # 页级: 括号闭合
            total_anom += 1
            if total_anom <= 20:
                print(f"  p{page['page']} [页级]: {f}")
    if total_anom > 20:
        print(f"  ... 另有 {total_anom - 20} 条")
    if total_anom == 0:
        print("  (无)")

    # --- 2b. 高频 n-gram: 捕捉「两引擎一起错」的专有名词 ---
    all_lines = [l["text"] for p in doc["pages"] for l in p["lines"]]
    grams = frequent_ngrams(all_lines)
    print(f"\n=== 高频词组 (人工扫一眼, 认出被误读的专有名词) ===")
    print("  跨引擎分歧抓不到这类 —— 两个引擎输出一致就不产生分歧,")
    print("  但专有名词必然高频复现, 人一眼能认出哪个不对。")
    for s, c in grams[:18]:
        print(f"  {c:>3}x  {s}")

    # --- 3. 应用术语表 ---
    print(f"\n=== 术语表 ({rel(gpath) if gpath.exists() else '未配置'}) ===")
    print(f"  规则数: {len(rules)}")
    if "--apply" in sys.argv:
        fixed = 0
        for page in doc["pages"]:
            for line in page["lines"]:
                line["text"], n = apply_glossary(line["text"], rules)
                fixed += n
        out = ROOT / "work" / f"{Path(cc['source']).stem}.{src_engine}.corrected.json"
        out.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"  已修正 {fixed} 处 -> {rel(out)}")
    else:
        print("  (未加 --apply, 仅检测未改动)")

    print(f"\n小结: 术语候选 {len(cands)} 组 | 语言学异常 {total_anom} 处 "
          f"| 交叉验证可疑 {len(items)} 条")


if __name__ == "__main__":
    main()
