#!/usr/bin/env python3
"""
阶段 6: 输出 Markdown 到 output/  (保留版面, 去除页眉页脚)

版面靠坐标推断, 阈值全部从数据算出, 不硬编码:
  * 首行缩进 vs 回行顶格  -> x 坐标双峰, 阈值取两峰之间的谷
  * 段落/区块分隔          -> y 间距 > 正常行距的 1.5 倍
  * 页眉页脚              -> 位于页面上/下缘, 且跨页重复出现
  * 页码                  -> 下缘、窄、纯数字

页眉检测会把判定结果打印出来, 便于人工确认（正式文件务必先看这一段）。
可用 config/strip.txt 追加强制删除的模式(每行一个正则)。

用法:
  .venv/bin/python src/to_markdown.py work/X.rapidocr.json \
      [--fixes review-fixes.json] [--glossary config/glossary.txt] [--dry]
"""
import json
import re
import statistics
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from normalize import canonical_action

ROOT = Path(__file__).resolve().parent.parent

EDGE_FRAC = 0.15      # 页面上/下 15% 视为页眉页脚候选区
                      # (实测 12% 会漏掉尺寸较大那页的标题行)
BLOCK_GAP = 1.5       # y 间距超过正常行距的这个倍数 => 区块分隔
HEADING_RE = re.compile(r"^\s*\d+[、.，]\s*\S")   # 场景标题: 11、xxx


# ---------- 阈值推断 ----------

def indent_threshold(lines: list[dict], page_w: int) -> float:
    """从 x 坐标的双峰分布里找谷底作为缩进阈值。

    三个必须注意的点(都是实测踩出来的):
      1. 必须在**去掉页眉之后**调用 —— 页眉的 x 是离群值(居中标题、右上角
         版权), 会把"最大间隔"吸引过去。
      2. 必须**按页**计算 —— 手机逐页拍摄时每页尺寸和边距都不同, 全局统一
         的像素阈值本身就是错的。
      3. 必须过滤贴边噪声(x≈0) —— 扫描边缘的伪检测会制造巨大的假间隔。
    """
    xs = sorted(l["x"] for l in lines
                if page_w * 0.015 < l["x"] < page_w * 0.35)
    if len(xs) < 4:
        return statistics.median(xs) if xs else 0.0
    best_gap, best_mid = 0.0, statistics.median(xs)
    for a, b in zip(xs, xs[1:]):
        if b - a > best_gap:
            best_gap, best_mid = b - a, (a + b) / 2
    return best_mid


def line_pitch(pages_lines: list[list[dict]]) -> float:
    """正常行距。必须**按页**算 —— 跨页把 y 混在一起排序会产生大量假间隔。"""
    gaps: list[float] = []
    for lines in pages_lines:
        ys = sorted(l["y"] for l in lines)
        gaps += [b - a for a, b in zip(ys, ys[1:]) if 0 < b - a < 400]
    return statistics.median(gaps) if gaps else 50.0


# ---------- 页眉页脚 ----------

MAX_HEADER_LEN = 25   # 页眉都很短; 长句是正文, 绝不当页眉删
HEAD_RANK = 4         # 只有每页最靠前的这几行才有资格当页眉
FOOT_RANK = 2         # 最靠后的这几行才有资格当页脚


def in_edge(line: dict, page_h: int) -> bool:
    cy = line["y"] + line["h"] / 2
    return cy < page_h * EDGE_FRAC or cy > page_h * (1 - EDGE_FRAC)


def find_headers(pages: list[dict]) -> tuple[set[str], list[str]]:
    """跨页重复 + 位于页缘 + 足够短 => 页眉页脚。

    实测坑: OCR 对页眉本身的识别也会逐页不同(同一个 logo 读成 '中汇' /
    '中汇影视'), 所以精确匹配会漏。调用方需再做一次模糊匹配兜底。
    """
    n = len(pages)
    need = max(2, (n + 1) // 2)        # 至少半数页面出现
    edge_texts: Counter = Counter()

    for p in pages:
        H = p["height"] or 1
        ordered = sorted(p["lines"], key=lambda l: l["y"])
        # 位置约束: 只有最靠前 HEAD_RANK 行 / 最靠后 FOOT_RANK 行才够资格。
        # 否则正文里恰好跨页重复的句子(页缘附近)会被误判成页眉。
        cand = ordered[:HEAD_RANK] + ordered[-FOOT_RANK:]
        s = {l["text"].strip() for l in cand
             if in_edge(l, H) and 0 < len(l["text"].strip()) <= MAX_HEADER_LEN}
        edge_texts.update(s)

    repeated = {t for t, c in edge_texts.items() if c >= need and t}
    report = [f"跨页重复({edge_texts[t]}/{n}页): {t!r}" for t in sorted(repeated)]
    return repeated, report


def fuzzy_header(text: str, drop: set[str], thresh: float = 0.6) -> str | None:
    """页缘文本与已确认页眉的模糊匹配, 兜住 OCR 的逐页变体。

    只在页缘区调用, 且只对短文本生效 —— 正文段落长, 不会被误伤。
    """
    t = text.strip()
    if not t or len(t) > MAX_HEADER_LEN:
        return None
    for d in drop:
        if not d:
            continue
        # 一方包含另一方(中汇 vs 中汇影视), 或字符集高度重合
        if t in d or d in t:
            return d
        common = len(set(t) & set(d))
        if common / max(len(set(t)), len(set(d))) >= thresh:
            return d
    return None


def is_page_number(line: dict, page_h: int) -> bool:
    cy = line["y"] + line["h"] / 2
    t = line["text"].strip()
    return (cy > page_h * (1 - EDGE_FRAC)
            and len(t) <= 4
            and bool(re.fullmatch(r"[\dOolI|·\-—\s]+", t)))


def load_strip_patterns() -> list[re.Pattern]:
    f = ROOT / "config" / "strip.txt"
    pats = []
    if f.exists():
        for raw in f.read_text("utf-8").splitlines():
            s = raw.split("#", 1)[0].strip()
            if s:
                try:
                    pats.append(re.compile(s))
                except re.error as e:
                    print(f"  [警告] config/strip.txt 正则无效: {s!r} ({e})",
                          file=sys.stderr)
    return pats


# ---------- 正文组装 ----------

# 剧本结构的文本特征 —— 比 x 阈值可靠得多(实测正式文件有 4~5 级缩进,
# 双峰假设完全不成立; 而文本模式是确定性的)
# 场景标题: 数字编号是主场景(1. 曼谷唐人街 日 外);
# 单字母编号是蒙太奇段落里的子场景(A. 国际航班机舱内 夜 内) —— 实测本剧本
# 两种并存, 只认数字会让字母那些落到「沿用上一段类型」的分支, 对错全看运气。
SCENE_RE = re.compile(r"^\s*(?:\d{1,3}|[A-Za-z])\s*[.、．]\s*\S")
SPEAKER_RE = re.compile(r"^\s*[^\s：:，。！？]{1,12}"
                        r"(?:[（(][^）)]{0,12}[）)])?\s*[：:]")  # 阿楠（泰语）：
# 句末标点: 上一段以此结尾时, 下一行不可能是它的续行
SENT_END = tuple("。！？!?…”》」』")


def page_to_blocks(kept: list[dict], margin: float,
                   pitch: float) -> list[tuple[str, str]]:
    """返回 [(类型, 文本)]，类型 ∈ {title, heading, action, speech, para}。

    判定优先级(文本特征优先, x 只作辅助):
      场景标题 > 动作行(△) > 对白行(角色：) > 续行
    """
    kept = sorted(kept, key=lambda l: (l["y"], l["x"]))
    at_margin = lambda l: l["x"] <= margin + pitch      # 容差一个行距

    # --- 预处理: 孤立的 △ 标记 ---
    # OCR 有时把标记单独切成一个框, 且其 y 未必排在正文行之前。
    # 按**垂直重叠**找它真正属于哪一行, 打标后丢弃这个孤立框。
    orphans = [l for l in kept
               if canonical_action(l["text"].strip()) == (True, "")]
    if orphans:
        rest = [l for l in kept if l not in orphans]
        for o in orphans:
            best, best_ov = None, 0.0
            oy0, oy1 = o["y"], o["y"] + o["h"]
            for r in rest:
                ov = min(oy1, r["y"] + r["h"]) - max(oy0, r["y"])
                if ov > best_ov:
                    best, best_ov = r, ov
            if best is not None and best_ov > 0:
                best["_forced_action"] = True
        kept = rest

    # 从「确认无疑的 △ 行」反推动作行的 x 基准, 续行一定比它更靠右
    act_xs = sorted(l["x"] for l in kept
                    if canonical_action(l["text"].strip())[0]
                    and any(c in "△▲Δ∆◇◆" for c in l["text"][:3]))
    cont_thr = None
    if len(act_xs) >= 4:
        base = act_xs[len(act_xs) // 2]          # 动作行 x 中位数
        cont_thr = base + pitch * 0.55           # 超过这个就是续行缩进

    blocks: list[tuple[str, str]] = []
    prev_bottom = None
    for l in kept:
        raw = l["text"].strip()
        if not raw:
            continue
        gap_break = (prev_bottom is not None
                     and l["y"] - prev_bottom > pitch * (BLOCK_GAP - 1))
        is_action, body = canonical_action(raw)
        if l.get("_forced_action") and not is_action:
            is_action, body = True, raw

        if is_action and not body:
            prev_bottom = l["y"] + l["h"]
            continue

        # 场景标题容差放宽到 3 个行距 —— 实测有标题缩进到 x=212 而页边距
        # 才 ~100, 一个行距的容差会把它漏掉(场景 51)。
        # 「数字/字母 + 句点 + 中文」这个模式本身足够独特, 放宽是安全的。
        if SCENE_RE.match(raw) and l["x"] <= margin + pitch * 3:
            blocks.append(("heading", raw))
        elif is_action:
            blocks.append(("action", body))
        elif SPEAKER_RE.match(raw) and at_margin(l):
            blocks.append(("speech", raw))
        elif not blocks or gap_break:
            blocks.append(("para", raw))
        elif cont_thr is not None and l["x"] < cont_thr:
            # x 仍在动作行一级(未退到续行缩进) => 是新段落而非续行
            blocks.append((blocks[-1][0], raw))
        else:
            kind, prev = blocks[-1]
            # 中文续行直接相接; 但英文/数字跨行要补空格, 否则
            # "Sorry for long" + "time!" 会粘成 "longtime!"
            sep = " " if (prev and raw
                          and prev[-1].isascii() and prev[-1].isalnum()
                          and raw[0].isascii() and raw[0].isalnum()) else ""
            blocks[-1] = (kind, prev + sep + raw)
        prev_bottom = l["y"] + l["h"]
    return blocks


def dedup_overlapping(pages: list[dict]) -> int:
    """去掉「同一视觉行被两个引擎各检出一份」造成的重复。

    合并另一引擎独有的行是必要的(否则整行内容丢失), 但当 match_lines
    没能把两份配上对时, 两份都会进入正文。回填/术语表把它们修成同一句
    之后, 成稿里就出现紧挨着的重复。

    判据是**几何重叠**, 不是文本相同 —— 剧本里合理的重复(如失智老人
    反复说「返，返，返」)分布在不同 y, 不会被误删。
    """
    # 用 equiv 而非 norm 严格相等 —— 同一行的两份检出常常一份带 △
    # 一份不带(另一引擎漏检了标记), 严格相等会判成不同而漏去重。
    from normalize import equiv
    removed = 0
    for p in pages:
        lines = sorted(p["lines"], key=lambda l: (l["y"], l["x"]))
        keep, drop_idx = [], set()
        for i, a in enumerate(lines):
            if i in drop_idx:
                continue
            for j in range(i + 1, len(lines)):
                b = lines[j]
                if b["y"] > a["y"] + a["h"]:        # 已经不可能重叠
                    break
                ov = min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"])
                if ov <= 0:
                    continue
                if ov / max(1e-6, min(a["h"], b["h"])) < 0.5:
                    continue
                if equiv(a["text"], b["text"]):
                    drop_idx.add(j)
                    removed += 1
            keep.append(a)
        p["lines"] = [l for k, l in enumerate(lines) if k not in drop_idx]
    return removed


def apply_fixes(pages: list[dict], fixes: dict, cc: dict | None) -> tuple[int, int]:
    """review-fixes.json: {crosscheck条目序号: 校对后文本} -> 回填正文。

    **必须按几何位置定位**, 不能用文本模糊匹配。曾经的做法是「替换所有
    相似度 >=75% 的行」, 结果一条校对结果会覆盖掉多行 —— 实测下半部分
    「阿公……走丢了？」被写到了两处, 其中一处原本是别的台词, 被静默改写。
    校对条目本来就带页码和裁切框, 用它精确定位即可。
    """
    if not fixes or not cc:
        return 0, 0
    items = cc["items"]
    done = miss = 0
    claimed: set[int] = set()      # 已被认领的行(id), 一行只能被一条校对结果写

    # 先算出每条校对结果对每一行的重叠度, 再按重叠度从高到低分配 ——
    # 否则两条指向同一视觉行的校对结果(一条来自各引擎)会写到同一行上,
    # 后写的覆盖先写的。实测: 「15. 陈洪礼老宅日外」被无编号的那份覆盖,
    # 去重再把两行合并, 场景编号就此消失。
    cand: list[tuple[float, int, dict, str]] = []
    for key, text in fixes.items():
        i = int(key)
        if i >= len(items):
            miss += 1
            continue
        it = items[i]
        page = next((p for p in pages if p["page"] == it["page"]), None)
        if page is None:
            miss += 1
            continue
        cx, cy, cw, ch = it["crop"]
        for l in page["lines"]:
            ov = min(cy + ch, l["y"] + l["h"]) - max(cy, l["y"])
            hov = min(cx + cw, l["x"] + l["w"]) - max(cx, l["x"])
            if ov > 0 and hov > 0:
                cand.append((ov, i, l, text))

    cand.sort(key=lambda t: -t[0])
    used_fix: set[int] = set()
    for ov, i, line, text in cand:
        if i in used_fix or id(line) in claimed:
            continue
        line["text"] = text
        used_fix.add(i)
        claimed.add(id(line))
        done += 1
    miss += sum(1 for k in fixes if int(k) not in used_fix and int(k) < len(items))
    return done, miss


def _close(a: str, b: str) -> bool:
    if not a or not b or abs(len(a) - len(b)) > 4:
        return False
    same = sum(1 for x, y in zip(a, b) if x == y)
    return same / max(len(a), len(b)) >= 0.75


def merge_engine(primary: dict, other: dict) -> int:
    """把另一个引擎**独有**的行插回主稿。

    必须做这一步: 主稿只用单个引擎时, 该引擎整行漏识别的内容会直接从
    输出里消失。实测上半部分.pdf 有 18 行只有 Vision 识别出来, 其中
    12 行在以 RapidOCR 为底稿的成稿中完全不见了 —— 是内容丢失, 不是
    格式问题。
    """
    from crosscheck import match_lines
    added = 0
    for pp, po in zip(primary["pages"], other["pages"]):
        la, lb = pp["lines"], po["lines"]
        pairs, _, only_b = match_lines(la, lb)
        for j in only_b:
            extra = dict(lb[j])
            extra["_from"] = other["engine"]
            la.append(extra)
            added += 1
        la.sort(key=lambda l: (l["y"], l["x"]))
    return added


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    src = Path(sys.argv[1]).resolve()
    doc = json.loads(src.read_text("utf-8"))
    pages = doc["pages"]
    stem = Path(doc["source"]).stem

    # 合并另一引擎独有的行(默认自动找同名的 vision/rapidocr 对应文件)
    merged = 0
    if "--no-merge" not in sys.argv:
        if "--merge" in sys.argv:
            op = Path(sys.argv[sys.argv.index("--merge") + 1]).resolve()
        else:
            other_engine = "vision" if doc["engine"] != "vision" else "rapidocr"
            op = src.with_name(f"{stem}.{other_engine}.json")
        if op.exists():
            merged = merge_engine(doc, json.loads(op.read_text("utf-8")))

    # 先回填人工校对(需要 crosscheck 提供页码/坐标来精确定位)
    rfix = rmiss = 0
    if "--fixes" in sys.argv:
        fp = Path(sys.argv[sys.argv.index("--fixes") + 1]).resolve()
        ccp = src.with_name(f"{stem}.crosscheck.json")
        cc = json.loads(ccp.read_text("utf-8")) if ccp.exists() else None
        if cc is None:
            print(f"[警告] 找不到 {ccp.name}, 无法定位校对结果, 已跳过回填",
                  file=sys.stderr)
        rfix, rmiss = apply_fixes(pages, json.loads(fp.read_text("utf-8")), cc)

    # 再应用术语表 —— 必须在回填**之后**, 否则人工稿会把
    # 术语表已修好的地方覆盖回去(实测: 眺英歌 被覆盖回来)
    if "--glossary" in sys.argv:
        gp = Path(sys.argv[sys.argv.index("--glossary") + 1]).resolve()
    else:
        gp = ROOT / "config" / "glossary.txt"
    sys.path.insert(0, str(ROOT / "src"))
    from postcheck import load_glossary, apply_glossary
    rules = load_glossary(gp)
    gfix = 0
    if rules:
        for p in pages:
            for l in p["lines"]:
                l["text"], k = apply_glossary(l["text"], rules)
                gfix += k

    # 去掉「同一行被两引擎各检出一份」的重复(必须在回填+术语表之后)
    deduped = dedup_overlapping(pages)

    # 先定页眉, 再用**正文行**算阈值 —— 顺序反了会被页眉的离群 x 带偏
    drop, report = find_headers(pages)
    pats = load_strip_patterns()

    fuzzy_hits: list[str] = []

    def is_body(l: dict, page: dict) -> bool:
        t = l["text"].strip()
        if not t or t in drop or is_page_number(l, page["height"]):
            return False
        if any(p.search(t) for p in pats):
            return False
        if in_edge(l, page["height"]):
            m = fuzzy_header(t, drop)
            if m is not None:
                fuzzy_hits.append(f"{t!r} ~ {m!r}")
                return False
        return True

    body_per_page = [[l for l in p["lines"] if is_body(l, p)] for p in pages]
    body_all = [l for ls in body_per_page for l in ls]
    all_lines = [l for p in pages for l in p["lines"]]

    # 每页的左边距: 取正文行 x 的 10 分位(稳健, 不被个别贴边噪声带偏)
    def margin_of(ls):
        xs = sorted(l["x"] for l in ls)
        return xs[len(xs) // 10] if len(xs) >= 10 else (xs[0] if xs else 0.0)
    thrs = [margin_of(ls) for ls in body_per_page]
    pitch = line_pitch(body_per_page)

    print(f"引擎 {doc['engine']} · {len(pages)} 页 · {len(all_lines)} 行"
          f" (正文 {len(body_all)} 行)")
    if merged:
        print(f"合并另一引擎独有的 {merged} 行(否则这些内容会整行丢失)")
    if deduped:
        print(f"去重 {deduped} 行(同一视觉行的两份检出)")
    print(f"左边距(按页) x={min(thrs):.0f}~{max(thrs):.0f}"
          f"   正常行距 {pitch:.0f}px   区块间隔 >{pitch*(BLOCK_GAP-1):.0f}px")
    if rules:
        print(f"术语表 {len(rules)} 条, 修正 {gfix} 处")
    if rfix or rmiss:
        print(f"校对结果回填 {rfix} 行" + (f", {rmiss} 条未能定位" if rmiss else ""))
    print(f"\n=== 判定为页眉页脚而删除的内容 ({len(drop)} 项) ===")
    print("  ⚠ 正式文件请务必核对这一段, 误删正文会很难发现")
    for r in report:
        print(f"  {r}")
    if fuzzy_hits:
        print(f"  模糊匹配额外删除 {len(fuzzy_hits)} 行(OCR 逐页变体):")
        for h in fuzzy_hits:
            print(f"    {h}")
    if pats:
        print(f"  另有 config/strip.txt 的 {len(pats)} 条强制规则")
    if not drop and not pats:
        print("  (未检出)")

    # 组装 Markdown
    out_lines = [f"# {stem}", ""]
    total_blocks = 0
    for body, thr in zip(body_per_page, thrs):
        blocks = page_to_blocks(body, thr, pitch)
        total_blocks += len(blocks)
        for kind, text in blocks:
            if kind == "heading":
                out_lines += [f"## {text}", ""]
            elif kind == "action":
                out_lines += [f"△ {text}", ""]      # 动作行保留标记
            else:
                out_lines += [text, ""]

    # 丢弃 OCR 噪声碎块: 无实质中文, 或极短且括号不配对(水印/边缘伪检测)
    def is_noise(t: str) -> bool:
        body = re.sub(r"^#+\s*", "", t).strip()
        cjk = len(re.findall(r"[\u4e00-\u9fff]", body))
        if cjk == 0:
            return True
        if t.startswith("#") and not re.search(r"[\u4e00-\u9fff]{2}", body):
            return True          # 只有编号没有场景名的残缺标题
        if len(body) < 10:
            bal = 0
            for ch in body:
                bal += ch in "（〔【｛［《〈「『("
                bal -= ch in "）〕】｝］》〉」』)"
                if bal < 0:
                    return True
            if bal != 0:
                return True
        return False

    kept_lines, dropped = [], 0
    for ln in out_lines:
        if ln.strip() and is_noise(ln):
            dropped += 1
            continue
        kept_lines.append(ln)
    if dropped:
        print(f"丢弃噪声碎块 {dropped} 个")
    out_lines = kept_lines

    # 成稿标点归一(比对阶段的 normalize 只用于判等, 不改文本, 这里才落到成稿)
    def polish(t: str) -> str:
        # 省略号各种读法 -> ……   注意保留单个 · (《归潮·家己人》里是间隔号)
        t = re.sub(r"[•⋯‥]+|\.{3,}|·{2,}", "……", t)
        t = re.sub(r"(?:……){2,}", "……", t)
        # 行首游离的右括号(OCR 把水印/边框误检成标点)
        t = re.sub(r"^(#+\s*|△\s*)?[）〕】｝］》〉」』)\]]+\s*", r"\1", t)
        return t

    out_lines = [polish(l) if l.strip() else l for l in out_lines]

    md = "\n".join(out_lines).rstrip() + "\n"
    md = re.sub(r"\n{3,}", "\n\n", md)

    outdir = ROOT / "output"
    outdir.mkdir(exist_ok=True)
    out = outdir / f"{stem}.md"
    if "--dry" in sys.argv:
        print(f"\n[--dry] 不写文件。预览前 20 行:\n")
        print("\n".join(md.splitlines()[:20]))
    else:
        out.write_text(md, encoding="utf-8")
        print(f"\n-> {out.relative_to(ROOT)}  ({total_blocks} 个区块, {len(md)} 字符)")


if __name__ == "__main__":
    main()
