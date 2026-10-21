#!/usr/bin/env python3
"""
书籍线 阶段 4: work/<名>.fused.json -> output/<名>.md  (段落化正文)

与剧本线的 src/to_markdown.py **完全独立**。剧本靠「场景标题 / △动作行 /
角色（…）：对白」判版面; 书籍没有这些特征, 只能靠「页眉页脚 + 首行缩进 +
行尾留白」。两套版面逻辑不共用, 本模块只从 normalize.py 借纯工具函数。

规则(逐条对应需求):
  1. 去页眉页脚 —— 跨页重复的页缘短行 / 纯页码(阿拉伯·罗马·汉字) /
     「第X章 …」式书眉。书眉的本质是**跨页重复**: 字号只是辅助信号
     (中文简装书把章标题排成与正文同字号很常见, 扫描件的 OCR 框高也不等于
     字号), 所以「第X章 …」和页码都要求在 >= 2 页(页码还要同一位置)出现过
     才删 —— 全书只出现一次的「第三章 归途」是章标题, 不是书眉。
     阈值一律**按页**算(每页尺寸可能不同), 正文左右边距必须在
     去掉页眉**之后**才算 —— 页眉是居中/贴角的离群值, 会污染边距。
  2. 段落合并 —— 首行缩进 >= 正文左边距 + 1.5 字宽 => 新段;
     上一行右端 < 正文宽的 85% => 上一段在那里结束。两条都不满足就是续行,
     跨页也照样接上。中文之间**不补空格**, 只有两侧都是 ASCII 字母数字
     才补一个; 西文行尾连字符拼回整词(post- + marked -> postmarked)。
  3. 标题 —— 行高显著大于该页正文中位行高、左右边距接近对称(居中)、长度短,
     命中「第…章/第…节/序/前言/后记/目录/附录」加权。一级 '# ', 次级 '## '。
  4. 每页开头插 <!-- page N --> 便于回溯。若该页首行是上一段的**续行**,
     注释改为**行内**: CommonMark 里 HTML 注释属于能打断段落的 HTML 块,
     单独成行会把规则 2 辛苦接起来的跨页段落又切断。
  5. 噪声过滤 —— 无汉字且无字母数字的碎块、孤立标点、贴页缘的小碎块、
     极矮的碎块、「比正文小且上下都孤零零」的碎块。每一条丢弃都**连原文一起**
     记下来(stats['dropped_lines']), 从不静默吞行。
     置信度判据只对 RapidOCR 的连续值生效 —— Vision 的 0.3/0.5/1.0 三档与
     对错无关(CLAUDE.md 不变量), 拿它丢行会吃掉「三」「完」这种单字正文。
  6. 竖排检测 —— 整页绝大多数行「高 > 宽」且横向铺开 => 本版**不支持**,
     告警 + 在 md 里留 WARNING 注释, 该页按原行照常输出, 不假装处理了。
  7. 双栏检测 —— 页中间有一条贯穿多数行的空白竖带 => 按竖带切成左右两栏,
     每栏各自算版心度量、各自走一遍段落合并(否则左右会被交错拼成乱码),
     并在 md 里留 WARNING 注释 + 进报告, 让用户知道这页要复核。

用法:
  .venv/bin/python src/book_md.py work/<名>.fused.json \\
      [--out output/<名>.md] [--force] [--keep-page-marks|--no-page-marks]

默认输出 output/<名>.md, **已存在就拒绝写**(output/ 下的文件是别的 fork 的
输入, 静默覆盖是严重事故), 要覆盖必须显式 --force。

供驱动调用: to_markdown(fused: dict, opts: Options | dict | None) -> str
"""
from __future__ import annotations

import argparse
import bisect
import json
import math
import re
import statistics
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from normalize import norm  # 纯工具: NFKC + 等价字符折叠 + 去空白

ROOT = Path(__file__).resolve().parent.parent

_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)


# ============================ 可调参数 ============================

EDGE_FRAC = 0.12        # 页面上/下 12% 视为页眉页脚候选区(按页算)
HEAD_RANK = 3           # 每页最靠前的这几行才有资格当页眉
FOOT_RANK = 2           # 最靠后的这几行才有资格当页脚
MAX_HEAD_LEN = 30       # 页眉都很短; 长句是正文, 绝不当页眉删
HEAD_MAX_RATIO = 1.18   # 页眉/页码的行高上限(相对该页中位行高)。
                        # 字号只是**辅助**信号: 它区分不了与正文同字号的章标题,
                        # 真正的判据是跨页重复(见 CHAP_HEAD_MIN_PAGES / need)。
FUZZY_THRESH = 0.6      # 页眉模糊兜底: OCR 对页眉本身也逐页读得不同
FUZZY_MIN_LEN = 3       # 模糊兜底的子串分支: 候选键至少这么长才算数
FUZZY_MIN_COVER = 0.6   # 且至少覆盖书眉的这个比例 —— 否则「来信」会把
                        # 页脚区一个两字的正文短行当成「灯下的来信」删掉

CHAP_HEAD_MIN_PAGES = 2  # 「第X章 …」式书眉: 同一文本至少在这么多页出现过才删。
                         # 只出现一次的一律保留, 交给 heading_level 判标题。
PAGENUM_MIN_PAGES = 2    # 页码: 同一「边 + 横向区位」至少在这么多页上出现过
PAGENUM_PAGES_FRAC = 0.25  # 且不少于总页数的这个比例(真页码逐页连续出现)。
                           # 孤零零一个「三」「1998」是小节号/年份, 不是页码。
PAGENUM_MAX_NEED = 8       # 但门槛封顶: 整本书 373 页时不该要求 94 页都认出
                           # 页码才肯删, 同一位置连续 8 页有数字已经够硬。

ISOLATE_GAP = 2.5       # 孤立碎块: 上下最近一行的中心距都超过这么多倍中位行高
ISOLATE_MAX_RATIO = 0.85  # 且比正文矮这么多 —— 扫描噪点的几何特征,
                          # 用来替代「Vision 低置信」这个不可用的信号

INDENT_CHARS = 1.5      # 首行缩进判定: >= 左边距 + 这么多字宽
SHORT_END = 0.85        # 行尾留白判定: 右端 < 正文宽的这个比例 => 段落结束
BLOCK_GAP = 1.6         # 同页内 y 间距 > 行距的这个倍数 => 段落分隔

VERT_TALL = 1.2         # 竖排判定: 行高 > 行宽 * 这个倍数
VERT_FRAC = 0.6         # 竖排判定: 这么大比例的行都是「高行」
VERT_SPREAD = 0.35      # 竖排判定: 这些行的 x 至少铺开页宽的这个比例

TWOCOL_GUTTER_CHARS = 2.5  # 双栏判定: 中缝至少这么宽(字宽的倍数)
TWOCOL_MIN_ROWS = 6        # 双栏判定: 整页至少这么多行才谈得上分栏
TWOCOL_SIDE_FRAC = 0.25    # 双栏判定: 中缝两侧各至少占这个比例的行
TWOCOL_CROSS_FRAC = 0.1    # 允许这个比例的行横跨中缝(通栏标题/噪声)

MERGE_GAP_CHARS = 3.0   # 同一视觉行的碎片合并: 水平间隔上限(字宽的倍数)。
                        # 原值 8 字宽会把双栏页的左右两栏直接粘成一行;
                        # 正文里 3 字宽以上的横向空隙本来就不是同一行。
                        # (实测: 2.0~8.0 对正文页的结果完全一样, 只有版权页
                        #  那种表格式版面有差别, 3.0 与原值在实测件上一致)


# ============================ 字符工具 ============================

# 汉字(含扩展区)。注意 CJK **标点**(U+3000-303F, U+FF00-FF65)故意不在内 ——
# 整行只有标点就是噪声。
_CJK_RE = re.compile(
    r"[㐀-䶿一-鿿豈-﫿\U00020000-\U0003ffff]")
# 「有意义的非汉字文字」: 拉丁/数字/假名/谚文
_WORD_RE = re.compile(r"[0-9A-Za-z぀-ヿ가-힯]")


def _has_cjk(t: str) -> bool:
    return bool(_CJK_RE.search(t))


def _has_word(t: str) -> bool:
    return bool(_WORD_RE.search(t))


def _ascii_alnum(ch: str) -> bool:
    return ch.isascii() and ch.isalnum()


def splice(a: str, b: str) -> tuple[str, str, str]:
    """返回 (a', sep, b'), 拼起来 a'+sep+b' 就是合并结果。

    拆成三段而不是直接返回字符串, 是为了能在**接缝处**插入 <!-- page N -->
    (规则 4 的行内情形)。

      * 西文行尾连字符: 'post-' + 'marked' -> 'post' + '' + 'marked'
      * 两侧都是 ASCII 字母数字: 'lazy' + 'dog' -> 中间补一个空格
      * 其余(只要有一侧是中文): 不补空格
    """
    if not a:
        return "", "", b
    if not b:
        return a, "", ""
    if (a.endswith("-") and len(a) >= 2 and a[-2].isascii() and a[-2].isalpha()
            and b[0].isascii() and b[0].isalpha()):
        return a[:-1], "", b
    if _ascii_alnum(a[-1]) and _ascii_alnum(b[0]):
        return a, " ", b
    return a, "", b


def _quantile(vals: list[float], q: float) -> float:
    if not vals:
        return 0.0
    s = sorted(vals)
    if len(s) == 1:
        return float(s[0])
    pos = q * (len(s) - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(s) - 1)
    return float(s[lo] + (s[hi] - s[lo]) * (pos - lo))


# ============================ 页级度量 ============================

@dataclass
class PageMetrics:
    left: float = 0.0        # 正文左边距
    right: float = 0.0       # 正文右边界
    width: float = 0.0       # 正文宽
    char_w: float = 0.0      # 估计字宽(中文方块字 ≈ 行高)
    med_h: float = 0.0       # 正文中位行高
    pitch: float = 0.0       # 正常行距(基线间距)
    page_w: float = 0.0      # 页宽(像素)。标题居中判定要用, 见 heading_level


def page_metrics(rows: list[dict], page_w: float, page_h: float) -> PageMetrics:
    """**按页**计算正文边距/字号/行距。必须在去掉页眉页脚**之后**调用。"""
    pm = PageMetrics(page_w=float(page_w))
    if not rows:
        return pm
    hs = [r["h"] for r in rows if r["h"] > 0]
    pm.med_h = statistics.median(hs) if hs else 0.0
    pm.char_w = pm.med_h or (page_w * 0.03)

    # 左边距取 10% 分位而不是 min: min 会被残留碎块/斜拍抖动拉偏。
    # 缩进行只占少数, 不会把 10% 分位顶上去。
    xs = [r["x"] for r in rows]
    pm.left = _quantile(xs, 0.10)
    # 右边界取 90% 分位: 书籍绝大多数行都顶到版心右缘, 段末短行是少数。
    ends = [r["x"] + r["w"] for r in rows]
    pm.right = _quantile(ends, 0.90)
    pm.width = pm.right - pm.left
    if pm.width <= 0:
        pm.left, pm.right = 0.0, float(page_w)
        pm.width = float(page_w)

    ys = sorted(r["y"] for r in rows)
    gaps = [b - a for a, b in zip(ys, ys[1:]) if 0 < b - a < page_h * 0.3]
    pm.pitch = statistics.median(gaps) if gaps else (pm.med_h * 1.7 or 1.0)
    return pm


def provisional_med_h(lines: list[dict]) -> float:
    """去页眉**之前**的中位行高。

    鸡生蛋问题: 判页眉要用「不比正文大」这个条件, 而正文行高又要去掉页眉
    才准。中位数对少量页眉离群值不敏感, 所以用全页中位数做这一步的参照,
    去完页眉再重算一次真正的正文度量。
    """
    hs = [l["h"] for l in lines if l["h"] > 0]
    return statistics.median(hs) if hs else 0.0


# ============================ 噪声过滤(规则 5) ============================

def _isolated(line: dict, centers: list[float], med_h: float) -> bool:
    """这一行的上下**都**空出了一大片 —— 版心里孤零零一个小框 = 扫描噪点。

    必须上下都有邻居才谈得上「孤立」: 页首的小节号上面本来就没有东西,
    不能因此把它当噪点(实测: 只看单边会吃掉「三」这种与正文同字号的节号)。
    """
    if not med_h or not centers:
        return False
    cy = line["y"] + line["h"] / 2
    #  centers 由调用方排好序; 用二分找上下最近的邻居, 别对每一行扫全页
    #  (一页上千框的扫描件会退化成平方级)。
    i = bisect.bisect_left(centers, cy - 1e-6)
    j = bisect.bisect_right(centers, cy + 1e-6)
    if i == 0 or j >= len(centers):
        return False
    return (cy - centers[i - 1] > ISOLATE_GAP * med_h
            and centers[j] - cy > ISOLATE_GAP * med_h)


def noise_reason(line: dict, page_w: float, page_h: float,
                 med_h: float, centers: list[float] | None = None) -> str | None:
    """返回丢弃理由; None = 保留。每个理由都会被计数, 并连原文一起记下。

    `centers` 是本页所有行的 y 中心(含本行), 用于「孤立碎块」的几何判据;
    不传就跳过那一条。
    """
    t = line["text"].strip()
    if not t:
        return "空行"
    if not _has_cjk(t) and not _has_word(t):
        # 纯标点/符号: 「。」「·」「|||」「——」, 以及扫描噪点
        return "孤立标点或无文字碎块"
    w, h = line["w"], line["h"]
    x0, y0 = line["x"], line["y"]
    x1, y1 = x0 + w, y0 + h
    if len(t) <= 3 and (x1 < page_w * 0.02 or x0 > page_w * 0.98
                        or y1 < page_h * 0.02 or y0 > page_h * 0.98):
        return "贴页缘碎块"
    if med_h and h < med_h * 0.35 and len(t) <= 3:
        return "微小碎块"
    #  置信度判据: **只对 RapidOCR 的连续值生效**。
    #  Vision 的置信度只有 0.3/0.5/1.0 三档且与对错无关(CLAUDE.md 不变量),
    #  拿它当错误信号会把只有 Vision 读到的「三」「十一」「完」整行删掉 ——
    #  book_fuse._single_flag 也是只对 rapidocr 判 low_conf, 这里保持一致。
    #  src 缺失时按旧行为处理(老的 fused.json 没有这个字段)。
    conf = line.get("conf")
    src = line.get("src")
    if (conf is not None and conf < 0.4 and len(t) <= 2
            and src in (None, "both", "rapidocr")):
        return "低置信碎块"
    #  Vision 独有的碎块改用几何判据: 比正文矮一截, 且上下都孤零零。
    if (len(t) <= 2 and med_h and h < med_h * ISOLATE_MAX_RATIO
            and centers is not None and _isolated(line, centers, med_h)):
        return "孤立碎块"
    return None


# ============================ 同行碎片合并 ============================

def cluster_rows(lines: list[dict], char_w: float,
                 split_x: float | None = None) -> list[dict]:
    """把同一视觉行被 OCR 切成多块的碎片合成一行。

    不先合并的话, 「上一行右端是否留白」会被半截碎片骗到, 段落切得稀碎。
    垂直重叠判定, 不按 y 相等 —— 两个引擎融合后的框高低会差几个像素。

    **分两步**: 先按垂直重叠分组, 再在组内**按 x 排序**后拼接。
    合并顺序一定要用 x, 不能用扫描顺序(y 中心) —— 同一行的两块框高低差
    几个像素是常态, 按 y 中心排就会把后半句拼到前半句**前面**,
    整行内容倒过来, 而且表面上看不出是错的。(实测: ±2px 抖动即复现)

    `split_x` 是双栏页的中缝位置: 跨中缝的两块**绝不**合并, 否则左栏的
    这一行会和右栏的那一行被粘成一句乱码。
    """
    def _side(x: float) -> int:
        return 0 if split_x is None else int(x >= split_x)

    groups: list[dict] = []
    for l in sorted(lines, key=lambda l: (l["y"] + l["h"] / 2, l["x"])):
        #  单栏时只看最后一组(扫描顺序相邻); 分栏时左右两栏的框在扫描顺序上
        #  交替出现, 同栏的前一块可能已经不是最后一组, 要往回找。
        cands = [groups[-1]] if (groups and split_x is None) else list(
            reversed(groups[-4:]))
        for g in cands:
            ov = min(g["y1"], l["y"] + l["h"]) - max(g["y0"], l["y"])
            same_col = _side(l["x"] + l["w"] / 2) == _side(
                (g["x0"] + g["x1"]) / 2)
            if ov > 0.5 * min(g["y1"] - g["y0"], l["h"]) and same_col:
                gap = max(l["x"] - g["x1"], g["x0"] - (l["x"] + l["w"]), 0.0)
                if gap <= MERGE_GAP_CHARS * max(char_w, 1.0):
                    g["items"].append(l)
                    g["y0"] = min(g["y0"], l["y"])
                    g["y1"] = max(g["y1"], l["y"] + l["h"])
                    g["x0"] = min(g["x0"], l["x"])
                    g["x1"] = max(g["x1"], l["x"] + l["w"])
                    break
        else:
            groups.append({"items": [l], "x0": l["x"], "x1": l["x"] + l["w"],
                           "y0": l["y"], "y1": l["y"] + l["h"]})

    out: list[dict] = []
    for g in groups:
        items = sorted(g["items"], key=lambda l: l["x"])
        r = dict(items[0])
        text = r["text"]
        for nxt in items[1:]:
            a, sep, b = splice(text, nxt["text"])
            text = a + sep + b
        confs = [i["conf"] for i in items if i.get("conf") is not None]
        r.update({
            "text": text, "x": g["x0"], "y": g["y0"],
            "w": g["x1"] - g["x0"],
            # 行高取各块的最大值, 不取并集高度: 并集会被那几像素的高低差
            # 撑大, 而行高是标题判定的主信号, 不能让抖动污染它。
            "h": max(i["h"] for i in items),
            "_n": len(items),
        })
        if confs:
            r["conf"] = min(confs)
        out.append(r)
    return out


# ============================ 页眉页脚(规则 1) ============================

# 罗马页码只认 1..89 (i..lxxxix), 故意**不收** m/d/c。
# 完整的罗马数字文法会把英文单词也认成数字: 'mix' = MIX = 1009, 'dim' = DIM,
# 于是页缘上一个普通英文词就被当页码删掉。前言/目录的罗马页码从来不会上到
# 三位数, 砍掉 m/d/c 没有代价。
_ROMAN = re.compile(r"^(?=[ivxl])(xl|l?x{0,3})(ix|iv|v?i{0,3})$", re.I)
_PAGENUM_STRIP = r"[\s\-—–~～·.。、_=|/\\\[\]()（）<>〈〉《》【】“”\"']*"
_PAGENUM_CORE = re.compile(
    rf"^{_PAGENUM_STRIP}(?P<core>.+?){_PAGENUM_STRIP}$")
_CN_NUM = re.compile(r"^[〇零一二三四五六七八九十百千两]{1,6}$")
_RUNHEAD_CHAP = re.compile(
    r"^第[0-9０-９〇零一二三四五六七八九十百千两]{1,8}"
    r"[章節节回卷篇部集讲講课課]")


def page_number_kind(text: str) -> str | None:
    """页码的**种类**: 'arabic'(1~3 位) / 'long'(4 位以上) / 'roman' / 'cjk'。

    种类决定要不要额外的跨页证据(见 find_page_number_slots):
      * arabic / roman —— 页缘上孤零零一个 1~3 位数或 xvii, 不作他想, 直接删。
      * long —— 「1998」这种四位数多半是年份, 要逐页出现才敢当页码。
      * cjk —— 「三」「十一」在中文书里是小节号的常见写法, 同上。
    """
    m = _PAGENUM_CORE.match(text.strip())
    if not m:
        return None
    core = m.group("core").strip()
    if not core or len(core) > 8:
        return None
    if core.isdigit():
        return "arabic" if len(core) <= 3 else "long"
    if _ROMAN.match(core):
        return "roman"
    return "cjk" if _CN_NUM.match(core) else None


#  这几种必须有「同一位置逐页出现」的证据才算页码
PAGENUM_NEEDS_PROOF = ("long", "cjk")


def is_page_number(text: str) -> bool:
    """纯页码: 阿拉伯 / 罗马 / 汉字数字, 允许 — 17 — · (17) 这类装饰。

    **只看文本**。单独成行的「三」「1998」在这里一律为真, 要不要真当页码
    删掉, 由调用方结合跨页位置证据决定(page_number_kind / find_page_number_slots)。
    """
    return page_number_kind(text) is not None


def _head_key(text: str) -> str:
    """跨页比对用的键: 归一化后抹掉数字 —— 书眉常带页码/章号, 逐页不同。"""
    return re.sub(r"[0-9０-９]+", "", norm(text))


def _edge_candidates(rows: list[dict], page_h: float,
                     med_h: float) -> list[dict]:
    """页缘 + 排名靠前/靠后 + 够短 + **不比正文大** 的行。"""
    if not rows:
        return []
    ordered = sorted(rows, key=lambda r: r["y"])
    pool = ordered[:HEAD_RANK] + ordered[-FOOT_RANK:]
    seen: set[int] = set()
    cand = []
    for r in pool:
        if id(r) in seen:
            continue
        seen.add(id(r))
        cy = r["y"] + r["h"] / 2
        if not (cy < page_h * EDGE_FRAC or cy > page_h * (1 - EDGE_FRAC)):
            continue
        t = r["text"].strip()
        if not t or len(t) > MAX_HEAD_LEN:
            continue
        # 字号闸门: 书眉绝不会比正文大。少了这一条, 章标题(同样短、同样
        # 居中、同样在页顶)会被当成书眉删掉。
        if med_h and r["h"] > med_h * HEAD_MAX_RATIO:
            continue
        cand.append(r)
    return cand


def find_running_heads(pages_rows: list[tuple[dict, list[dict], float]]
                       ) -> tuple[set[str], list[str]]:
    """跨页重复出现的页缘短行 => 书眉/页脚。

    阈值取 1/4 页而不是半数: 书籍左右页的书眉往往不同(左页书名、右页章名),
    各自只出现在一半的页上; 换章后章名书眉又只覆盖该章若干页。
    """
    n = len(pages_rows)
    need = max(2, math.ceil(n * 0.25))
    counter: Counter = Counter()
    sample: dict[str, str] = {}
    for _p, rows, med_h in pages_rows:
        page_h = _p.get("height") or 1
        keys = set()
        for r in _edge_candidates(rows, page_h, med_h):
            t = r["text"].strip()
            if is_page_number(t):
                continue
            k = _head_key(t)
            if k:
                keys.add(k)
                sample.setdefault(k, t)
        counter.update(keys)
    repeated = {k for k, c in counter.items() if c >= need}
    report = [f"跨页重复 {counter[k]}/{n} 页: {sample.get(k, k)!r}"
              for k in sorted(repeated, key=lambda k: -counter[k])]
    return repeated, report


def _xzone(cx: float, page_w: float) -> int:
    """横向三分区位: 0 左 / 1 中 / 2 右。页码在左右页上常常左右互换。"""
    if page_w <= 0:
        return 1
    return 0 if cx < page_w / 3 else (1 if cx < page_w * 2 / 3 else 2)


def find_page_number_slots(pages_rows: list[tuple[dict, list[dict], float]]
                           ) -> tuple[set[tuple[str, int]], list[str]]:
    """哪些「边 + 横向区位」上真的有一套逐页连续的页码。

    is_page_number() 只看文本, 「三」「十一」「1998」「(十二)」统统为真 ——
    中文书里单独成行的小节号/年份长这样的太多了, 光靠文本判定会把它们
    当页码删掉(实测 t_chap: 与正文同字号的节号「三」整行消失)。
    真页码的决定性特征是**同一位置逐页出现**, 所以这里按位置统计页数,
    只有达到阈值的位置才允许在第 2 遍里删。
    """
    n = len(pages_rows)
    need = min(max(PAGENUM_MIN_PAGES, math.ceil(n * PAGENUM_PAGES_FRAC)),
               PAGENUM_MAX_NEED)
    counter: Counter = Counter()
    sample: dict[tuple[str, int], str] = {}
    for p, rows, med_h in pages_rows:
        page_h = float(p.get("height") or 1)
        page_w = float(p.get("width") or 1)
        slots = set()
        for r in _edge_candidates(rows, page_h, med_h):
            t = r["text"].strip()
            if not is_page_number(t):
                continue
            cy = r["y"] + r["h"] / 2
            edge = "top" if cy < page_h / 2 else "bottom"
            key = (edge, _xzone(r["x"] + r["w"] / 2, page_w))
            slots.add(key)
            sample.setdefault(key, t)
        counter.update(slots)
    slots = {k for k, c in counter.items() if c >= need}
    report = [f"页码位置 {k[0]}/{('左', '中', '右')[k[1]]}: "
              f"{counter[k]}/{n} 页(门槛 {need}), 样例 {sample.get(k)!r}"
              for k in sorted(slots)]
    weak = [k for k in sorted(counter) if k not in slots]
    if weak:
        shown = "、".join(f"{sample.get(k)!r}({counter[k]}/{n} 页)"
                         for k in weak[:6])
        more = f" …另 {len(weak) - 6} 处" if len(weak) > 6 else ""
        report.append(f"另有 {len(weak)} 个位置的数字行没到门槛 {need} 页"
                      f" —— 不当页码, 保留: {shown}{more}")
    return slots, report


def find_chapter_heads(pages_rows: list[tuple[dict, list[dict], float]]
                       ) -> tuple[set[str], list[str]]:
    """「第X章 …」式**书眉**的文本集合 —— 跨 >= CHAP_HEAD_MIN_PAGES 页才算。

    原先只要页缘上出现形如「第X章 …」就无条件删, 唯一的防线是字号闸门
    (书眉不会比正文大)。可中文简装书把章标题排成与正文同字号非常常见,
    扫描件里 OCR 的框高也不等于字号 —— 实测 4 页书的两个章标题全被删光。
    书眉的本质是跨页重复, 所以这里统计**整页所有行**里该文本出现过的页数:
    章标题页上那条标题 + 后续各页的书眉 >= 2 页, 删的是页缘那一条(大字
    标题本来就进不了页缘候选); 全书只出现一次的「第三章 归途」只能是章标题,
    保留, 交给 heading_level 去判级别。
    """
    counter: Counter = Counter()
    sample: dict[str, str] = {}
    for _p, rows, _m in pages_rows:
        keys = set()
        for r in rows:
            t = r["text"].strip()
            if not t or len(t) > MAX_HEAD_LEN or not _RUNHEAD_CHAP.match(t):
                continue
            k = _head_key(t)
            if k:
                keys.add(k)
                sample.setdefault(k, t)
        counter.update(keys)
    heads = {k for k, c in counter.items() if c >= CHAP_HEAD_MIN_PAGES}
    #  逐条只列**被判成书眉**的(那是要删的, 误删必须可查); 保留下来的
    #  章标题汇成一行 —— 几十章的书逐条列出来会把报告里真正要紧的
    #  丢弃明细挤出显示窗口(run_books 的报告只取前若干行)。
    report = [f"「第X章」式文本 {sample.get(k)!r} 出现在 {counter[k]} 页 => 书眉, 删"
              for k in sorted(heads, key=lambda k: -counter[k])]
    kept = [k for k in counter if k not in heads]
    if kept:
        shown = "、".join(repr(sample.get(k)) for k in sorted(kept)[:6])
        more = f" …另 {len(kept) - 6} 个" if len(kept) > 6 else ""
        report.append(f"「第X章」式文本 {len(kept)} 个只出现在 1 页 => "
                      f"当章标题保留: {shown}{more}")
    return heads, report


def fuzzy_head(key: str, heads: set[str]) -> bool:
    """页眉模糊兜底 —— OCR 对页眉本身也逐页读得不同(实测教训)。

    只在页缘短文本上调用, 正文段落长, 不会被误伤。

    子串分支必须带长度约束: 书眉「灯下的来信」会让页脚区任何两字短行
    (「来信」「灯下」, 段末那一行恰好落在页缘就会中招)被当书眉删掉。
    OCR 把书眉读漏通常只差一两个字, 不会只剩两个字 —— 所以要求候选键
    至少 FUZZY_MIN_LEN 个字, 且覆盖书眉 FUZZY_MIN_COVER 以上。
    """
    if not key:
        return False
    for h in heads:
        if not h:
            continue
        if key == h:
            return True
        if ((key in h or h in key)
                and min(len(key), len(h)) >= FUZZY_MIN_LEN
                and min(len(key), len(h)) >= FUZZY_MIN_COVER * max(len(key),
                                                                   len(h))):
            return True
        a, b = set(key), set(h)
        if a and b and len(a & b) / max(len(a), len(b)) >= FUZZY_THRESH:
            return True
    return False


# ============================ 标题(规则 3) ============================

_KEY_TOP = re.compile(
    r"^\s*(第[0-9０-９〇零一二三四五六七八九十百千两]{1,8}[章卷篇部]"
    r"|序[言章]?$|自序|前言|引言|导言|緒论|绪论|绪言|后记|後記|跋$"
    r"|附录|附錄|目录|目錄|结语|結語|尾声|尾聲|致谢|致謝)")
_KEY_SUB = re.compile(
    r"^\s*(第[0-9０-９〇零一二三四五六七八九十百千两]{1,8}[节節回集讲講课課]"
    r"|[0-9０-９〇零一二三四五六七八九十]{1,4}\s*[、.．·]\s*\S"
    r"|[〇零一二三四五六七八九十]{1,3}[\s　]+\S)")
#  OCR 常把小标题里「二　雪天的客人」的全角空格吃掉, 只剩「二雪天的客人」,
#  上面那条就不匹配了 —— 实测做旧 fixture 上这一条让二级标题掉成正文。
#  分隔符没了就只给 1 分(不是 2): 正文行也可能以「二」开头(「二楼的灯亮着」),
#  但正文行右端顶到版心右缘, 过不了 centered 那一关, 总分到不了 4。
_KEY_SUB_WEAK = re.compile(r"^\s*[〇零一二三四五六七八九十]{1,3}[\u4e00-\u9fff]")


def heading_level(row: dict, pm: PageMetrics) -> int | None:
    """打分决定是不是标题, 以及级别。返回 1 / 2 / None。"""
    t = row["text"].strip()
    if not t or len(t) > 40:        # 长句绝不是标题
        return None
    ratio = (row["h"] / pm.med_h) if pm.med_h else 1.0
    score = 0
    if ratio >= 1.6:
        score += 3
    elif ratio >= 1.25:
        score += 2
    elif ratio >= 1.12:
        score += 1

    left_gap = row["x"] - pm.left
    right_gap = pm.right - (row["x"] + row["w"])
    #  两侧都留白才谈得上居中。正文行(含首行缩进的那种)右端顶到版心右缘,
    #  right_gap≈0, 在这一关就被挡掉了。
    inset = (pm.width > 0 and left_gap > pm.width * 0.06
             and right_gap > pm.width * 0.06)
    #  居中有两种参照: 对正文块居中, 或对**页面**居中。实测扫描件的左右
    #  页边距常常不等(装订边更宽), 正文块中心偏离页心几十像素, 只按正文块
    #  判定会把一个页居中的小标题算成「偏右」而丢掉 2 分, 刚好跌破门槛。
    row_c = row["x"] + row["w"] / 2
    centered = inset and (
        abs(left_gap - right_gap) <= pm.width * 0.12
        or (pm.page_w > 0 and abs(row_c - pm.page_w / 2) <= pm.page_w * 0.06))
    if centered:
        score += 2
    if len(t) <= 20:
        score += 1

    top = bool(_KEY_TOP.match(t))
    sub = bool(_KEY_SUB.match(t))
    if top:
        score += 3
    elif sub:
        score += 2
    elif _KEY_SUB_WEAK.match(t):
        score += 1

    if score < 4:
        return None
    if top or ratio >= 1.6:
        return 1
    return 2


# ============================ 竖排(规则 6) ============================

def looks_vertical(lines: list[dict], page_w: float) -> bool:
    cand = [l for l in lines if len(l["text"].strip()) >= 2]
    if len(cand) < 3:
        return False
    tall = [l for l in cand if l["h"] > l["w"] * VERT_TALL]
    if len(tall) < VERT_FRAC * len(cand):
        return False
    xs = [l["x"] for l in tall]
    return (max(xs) - min(xs)) > page_w * VERT_SPREAD


# ============================ 双栏(规则 7) ============================

def looks_two_column(lines: list[dict], char_w: float
                     ) -> tuple[float, float] | None:
    """找一条贯穿多数行的空白竖带(中缝)。返回 (左界, 右界) 或 None。

    做法: 把各行的 x 区间投到横轴上做覆盖直方图, 找版心内部最宽的一段
    「几乎没有行覆盖」的竖带。只有竖带够宽(> TWOCOL_GUTTER_CHARS 字宽)、
    且两侧各有足够多的行, 才判双栏。

    竖排页不要调用这个 —— 竖排本来就每列一个窄框, 列间空白到处都是。
    """
    cand = [l for l in lines if l["w"] > 0 and l["text"].strip()]
    n = len(cand)
    if n < TWOCOL_MIN_ROWS:
        return None
    x_lo = min(l["x"] for l in cand)
    x_hi = max(l["x"] + l["w"] for l in cand)
    span = x_hi - x_lo
    if span <= 0 or char_w <= 0:
        return None
    nb = 240
    bw = span / nb
    cover = [0] * nb
    for l in cand:
        i0 = max(0, int((l["x"] - x_lo) / bw))
        i1 = min(nb - 1, int((l["x"] + l["w"] - x_lo) / bw))
        for i in range(i0, i1 + 1):
            cover[i] += 1
    allow = int(n * TWOCOL_CROSS_FRAC)   # 容忍通栏标题/噪声横跨中缝
    best = (0, 0, 0)                     # (长度, 起, 止)
    run = 0
    for i in range(nb):
        if cover[i] <= allow:
            run += 1
            if run > best[0] and i - run + 1 > 0 and i < nb - 1:
                best = (run, i - run + 1, i)
        else:
            run = 0
    if best[0] == 0:
        return None
    g0 = x_lo + best[1] * bw
    g1 = x_lo + (best[2] + 1) * bw
    if g1 - g0 < TWOCOL_GUTTER_CHARS * char_w:
        return None
    #  中缝得在版心中部, 不能是版心边上的一条留白(首行缩进/段末短行造成的)
    c = (g0 + g1) / 2
    if not (x_lo + span * 0.2 < c < x_lo + span * 0.8):
        return None
    left = [l for l in cand if l["x"] + l["w"] <= g0 + bw]
    right = [l for l in cand if l["x"] >= g1 - bw]
    need = max(2, int(n * TWOCOL_SIDE_FRAC))
    if len(left) < need or len(right) < need:
        return None
    return (g0, g1)


# ============================ 主流程 ============================

@dataclass
class Options:
    page_marks: bool = True
    indent_chars: float = INDENT_CHARS
    short_end: float = SHORT_END
    stats: dict = field(default_factory=dict)
    report: list[str] = field(default_factory=list)


def _as_options(opts) -> Options:
    if opts is None:
        return Options()
    if isinstance(opts, Options):
        return opts
    if isinstance(opts, dict):
        o = Options()
        for k, v in opts.items():
            if hasattr(o, k):
                setattr(o, k, v)
        return o
    o = Options()
    for k in ("page_marks", "indent_chars", "short_end"):
        if getattr(opts, k, None) is not None:
            setattr(o, k, getattr(opts, k))
    return o


def to_markdown(fused: dict, opts=None) -> str:
    """fused.json(已解析的 dict) -> Markdown 文本。不写文件。

    统计与判定报告回填到 opts.stats / opts.report, 调用方自行打印。
    """
    o = _as_options(opts)
    st = o.stats
    pages = fused.get("pages") or []
    dropped: Counter = Counter()
    st.update({"pages": len(pages), "lines_in": 0, "rows": 0,
               "kept_rows": 0, "paragraphs": 0, "headings": 0,
               "dropped": 0, "divergent": 0, "low_conf": 0,
               "only_one_engine": 0, "vertical_pages": [],
               "two_column_pages": [], "chars": 0})
    #  每一条被丢掉的行连**原文**一起记下来: 只有计数的话, 误删(把章标题
    #  当书眉、把小节号当页码)在报告里完全看不见, 没有人工校对环节的流水线
    #  里这等于永远查不出来。
    dropped_lines: list[dict] = []

    def drop(reason: str, pno, row: dict) -> None:
        dropped[reason] += 1
        dropped_lines.append({"page": pno, "reason": reason,
                              "text": row["text"].strip(),
                              "x": row["x"], "y": row["y"],
                              "w": row["w"], "h": row["h"]})

    # ---- 第 1 遍: 噪声过滤 + 碎片合行 + 竖排/双栏检测 ----
    # 元组是 (页, 行, 参照行高, 是否竖排, 双栏中缝)。版面标记随元组走,
    # 不靠页号回查 —— page 字段缺失时所有页的页号都是 None, 一页竖排会连累全部。
    prepped: list[tuple[dict, list[dict], float, bool,
                        tuple[float, float] | None]] = []
    malformed = 0

    def _clean(l: dict) -> dict:
        """几何字段缺失/非数时补 0, 并计数 —— **不丢文本**。

        一行里少个 'w' 就让整本 373 页的运行抛 KeyError 死掉, 对一条
        没有人工校对的全自动流水线是最糟的失败方式。缺字段的行照常
        往下走(几何判据对它一律不成立), 只在报告里记一笔。
        """
        nonlocal malformed
        r = dict(l)
        bad = False
        for k in ("x", "y", "w", "h"):
            v = r.get(k)
            if not isinstance(v, (int, float)) or v != v:   # 缺失/None/NaN
                r[k] = 0.0
                bad = True
            else:
                r[k] = float(v)
        if not isinstance(r.get("text"), str):
            r["text"] = "" if r.get("text") is None else str(r["text"])
            bad = True
        if bad:
            malformed += 1
        return r

    for pi0, p in enumerate(pages, 1):
        lines = [_clean(l) for l in (p.get("lines") or [])]
        st["lines_in"] += len(lines)
        for l in lines:
            if l.get("flag") == "divergent":
                st["divergent"] += 1
            elif l.get("flag") == "low_conf":
                st["low_conf"] += 1
            if l.get("src") in ("vision", "rapidocr"):
                st["only_one_engine"] += 1
        page_w = float(p.get("width") or 1)
        page_h = float(p.get("height") or 1)

        pno0 = p.get("page") or pi0
        if looks_vertical(lines, page_w):
            st["vertical_pages"].append(pno0)
            prepped.append((p, [dict(l) for l in
                                sorted(lines, key=lambda l: (-l["x"], l["y"]))],
                            provisional_med_h(lines), True, None))
            continue

        med0 = provisional_med_h(lines)
        #  _isolated 用二分查上下最近的邻居 -> centers 必须有序。
        #  fused.json 里的行不保证按 y 排好(两引擎融合后按配对顺序落盘)。
        centers = sorted(l["y"] + l["h"] / 2 for l in lines)
        kept = []
        for l in lines:
            why = noise_reason(l, page_w, page_h, med0, centers)
            if why:
                drop(why, pno0, l)
            else:
                kept.append(l)
        #  双栏判定要在**合行之前**做: 中缝窄的时候 cluster_rows 会先把
        #  左右两栏粘成一行, 中缝就再也看不见了。
        band = looks_two_column(kept, med0 or page_w * 0.03)
        if band:
            st["two_column_pages"].append(pno0)
        rows = cluster_rows(kept, med0 or page_w * 0.03,
                            split_x=(band[0] + band[1]) / 2 if band else None)
        st["rows"] += len(rows)
        prepped.append((p, rows, provisional_med_h(rows) or med0, False, band))

    # ---- 第 2 遍: 页眉页脚(必须跨页统计, 所以要独立一遍) ----
    body_pages = [(p, rows, m) for (p, rows, m, vert, _b) in prepped if not vert]
    heads, head_report = find_running_heads(body_pages)
    chap_heads, chap_report = find_chapter_heads(body_pages)
    pn_slots, pn_report = find_page_number_slots(body_pages)
    #  判定过程的流水账先攒着, **不**立刻进 o.report: 调用方(run_books 的
    #  build_report)只显示报告的前若干行, 而最要紧的是「丢了哪些行」和版面
    #  告警 —— 那两样必须排在前面, 否则几十章的书一来, 误删就再也看不见了。
    judge_report = head_report + chap_report + pn_report

    # (页, 行, 度量, 是否竖排, 是否打页标记, 双栏警告文本)
    page_bodies: list[tuple[dict, list[dict], PageMetrics, bool, bool,
                            str | None]] = []
    for pib, (p, rows, med0, vertical, band) in enumerate(prepped, 1):
        page_w = float(p.get("width") or 1)
        page_h = float(p.get("height") or 1)
        pno = p.get("page") or pib
        if vertical:
            page_bodies.append((p, rows, page_metrics(rows, page_w, page_h),
                                True, True, None))
            continue
        cand_ids = {id(r) for r in _edge_candidates(rows, page_h, med0)}
        #  字号闸门(HEAD_MAX_RATIO)是为了保护章标题, 但它也把「框高略高于
        #  正文」的页码一起挡在候选外 —— 实测真书 p8 的 '004' 框高比 1.205,
        #  只差一点点, 于是整条页码粘进正文末尾变成「…揭露这一腐004」,
        #  373 页里约 19 处。对**已经有跨页位置证据**的页码放宽这道闸门:
        #  证据来自 find_page_number_slots(同一边 + 同一横向区位逐页复现),
        #  章标题不会满足它, 所以放宽不会误伤。
        loose_ids = {id(r) for r in _edge_candidates(rows, page_h, 0.0)} - cand_ids
        body = []
        for r in rows:
            if id(r) in cand_ids:
                t = r["text"].strip()
                cy = r["y"] + r["h"] / 2
                slot = ("top" if cy < page_h / 2 else "bottom",
                        _xzone(r["x"] + r["w"] / 2, page_w))
                #  汉字数字/四位数要有「同一位置逐页都有」的证据才当页码,
                #  否则孤零零一个「三」「1998」会被当页码删掉(见
                #  find_page_number_slots)。1~3 位阿拉伯数字和罗马数字直接删。
                kind = page_number_kind(t)
                if kind and (kind not in PAGENUM_NEEDS_PROOF
                             or slot in pn_slots):
                    drop("页码", pno, r)
                    continue
                k = _head_key(t)
                if k in heads:
                    drop("书眉/页脚(跨页重复)", pno, r)
                    continue
                #  「第X章 …」只有跨页重复过才是书眉; 全书只出现一次的
                #  是章标题(哪怕与正文同字号), 一律保留。
                if _RUNHEAD_CHAP.match(t) and k in chap_heads:
                    drop("书眉(第X章式)", pno, r)
                    continue
                if fuzzy_head(k, heads):
                    drop("书眉/页脚(模糊匹配)", pno, r)
                    continue
            elif id(r) in loose_ids:
                #  只认页码, 且只认有跨页证据的槽位; 书眉/章标题走不到这里
                t = r["text"].strip()
                cy = r["y"] + r["h"] / 2
                slot = ("top" if cy < page_h / 2 else "bottom",
                        _xzone(r["x"] + r["w"] / 2, page_w))
                if page_number_kind(t) and slot in pn_slots:
                    drop("页码(框略高于正文, 凭跨页证据)", pno, r)
                    continue
            body.append(r)
        st["kept_rows"] += len(body)

        warn = None
        if band:
            warn = (f"<!-- WARNING: 第 {pno} 页疑似双栏(中缝 x≈"
                    f"{band[0]:.0f}~{band[1]:.0f}), 已按中缝切成左右两栏"
                    f"分别成段; 分栏识别可能出错, 请优先复核本页 -->")
            mid = (band[0] + band[1]) / 2
            left = [r for r in body if r["x"] + r["w"] / 2 < mid]
            right = [r for r in body if r["x"] + r["w"] / 2 >= mid]
            #  每栏**各自**算版心度量: 用整页宽去量, 每一行都「右端留白」,
            #  段落合并会退化成一行一段。
            page_bodies.append((p, left, page_metrics(left, page_w, page_h),
                                False, True, warn))
            page_bodies.append((p, right, page_metrics(right, page_w, page_h),
                                False, False, None))
            continue
        # 正文边距在**去掉页眉之后**才算
        page_bodies.append((p, body, page_metrics(body, page_w, page_h),
                            False, True, None))

    # ---- 第 3 遍: 标题 + 段落合并 + 页标记 ----
    blocks: list[str] = []
    pending: list[str] = []          # 还没落地的 <!-- page N -->
    cur: str | None = None           # 当前段落缓冲
    prev: dict | None = None         # 上一行(带 _pm/_page/_heading)

    def flush() -> None:
        nonlocal cur
        if cur is not None:
            t = cur.strip()
            if t:
                blocks.append(t)
                st["paragraphs"] += 1
                # 字数不算行内的 <!-- page N -->, 否则统计跟着页数虚涨
                st["chars"] += len(_COMMENT_RE.sub("", t))
            cur = None

    for pi, (p, body, pm, vertical, mark, warn) in enumerate(page_bodies, 1):
        # page 字段缺失时退回序号, 别在正文里留下 <!-- page None -->
        pno = p.get("page") or pi
        if o.page_marks and mark:
            pending.append(f"<!-- page {pno} -->")
        if warn or not mark:
            #  双栏页: 告警是块级 HTML, 会打断段落 —— 本来就该打断, 这一页
            #  的版面已经不可靠。右栏(mark=False)同样必须断开: 左栏末行和
            #  右栏首行在版面上毫无关系, 接起来就是乱码。
            flush()
            prev = None
            blocks.extend(pending)
            pending = []
            if warn:
                blocks.append(warn)

        if vertical:
            flush()
            prev = None
            blocks.extend(pending)
            pending = []
            blocks.append(
                f"<!-- WARNING: 第 {pno} 页疑似竖排(高>宽且分列), "
                f"本版不支持竖排版面, 以下按识别到的行原样输出 -->")
            for r in body:
                t = r["text"].strip()
                if t:
                    blocks.append(t)
                    st["chars"] += len(t)
            continue

        for r in body:
            lvl = heading_level(r, pm)
            text = r["text"].strip()
            if lvl:
                flush()
                blocks.extend(pending)
                pending = []
                blocks.append("#" * lvl + " " + text)
                st["headings"] += 1
                st["chars"] += len(text)
                prev = {"_heading": True}
                continue

            new_para = cur is None or _is_para_start(prev, r, pm, o)
            if new_para:
                flush()
                blocks.extend(pending)
                pending = []
                cur = text
            else:
                a, sep, b = splice(cur or "", text)
                cur = a + sep + "".join(pending) + b
                pending = []
            prev = {"_heading": False, "x": r["x"], "y": r["y"],
                    "w": r["w"], "h": r["h"], "_pm": pm, "_page": pno}

    flush()
    blocks.extend(pending)

    st["dropped"] = sum(dropped.values())
    st["dropped_detail"] = dict(dropped)
    st["dropped_lines"] = dropped_lines
    #  报告按**要紧程度**排: 版面告警 -> 丢弃明细(带原文) -> 判定流水账。
    #  调用方只取前若干行, 顺序就是可见性。
    st["malformed_lines"] = malformed
    if malformed:
        o.report.append(f"⚠ {malformed} 行的坐标字段残缺(已按 0 处理, 文本保留)"
                        f" —— fused.json 可能不完整, 请核对上游")
    if st["vertical_pages"]:
        o.report.append(f"⚠ 疑似竖排页: {st['vertical_pages']} —— "
                        f"本版不支持竖排, 已按识别到的行原样输出, 请人工复核")
    if st["two_column_pages"]:
        o.report.append(f"⚠ 疑似双栏页: {st['two_column_pages']} —— "
                        f"已按中缝分栏输出, 请优先复核这些页")
    #  丢弃明细: 按理由分组、带页号和**原文**。误删(章标题被当书眉、
    #  小节号被当页码)只能靠这几行查出来, 所以绝不能只给计数。
    by_reason: dict[str, list[str]] = {}
    for d in dropped_lines:
        by_reason.setdefault(d["reason"], []).append(
            f"p{d['page']} {d['text']!r}")
    #  先列**最可能是误删**的理由(页码/书眉会整行吃掉章标题、小节号),
    #  纯噪声碎块排后面。
    _RISK = ("页码", "书眉/页脚(跨页重复)", "书眉(第X章式)", "书眉/页脚(模糊匹配)")
    for reason in sorted(by_reason,
                         key=lambda r: (_RISK.index(r) if r in _RISK
                                        else len(_RISK), r)):
        items = by_reason[reason]
        shown = "、".join(items[:12])
        more = f" …另 {len(items) - 12} 条" if len(items) > 12 else ""
        o.report.append(f"丢弃 {reason} {len(items)} 行: {shown}{more}")
    o.report.extend(judge_report)
    md = "\n\n".join(b for b in blocks if b.strip())
    md = re.sub(r"\n{3,}", "\n\n", md)
    return md + "\n" if md else ""


def _is_para_start(prev: dict | None, row: dict, pm: PageMetrics,
                   o: Options) -> bool:
    """这一行是不是**新段落的开头**。"""
    if prev is None or prev.get("_heading"):
        return True
    # (a) 首行缩进: 中文书缩进 2 字, 留 0.5 字容差
    if row["x"] >= pm.left + o.indent_chars * pm.char_w:
        return True
    # (b) 上一行右端明显留白 => 上一段已经在那里结束(跨页同样适用:
    #     书籍每页最后一行通常也是满行, 短了就是真的段末)
    ppm: PageMetrics = prev["_pm"]
    if ppm.width > 0:
        frac = (prev["x"] + prev["w"] - ppm.left) / ppm.width
        if frac < o.short_end:
            return True
    # (c) 同页内行距突然变大。只在同一页比较 —— 跨页的 y 之差毫无意义
    #     (上一页末行 y 很大, 本页首行 y 很小), 同页用 PageMetrics 同一性判断。
    if ppm is pm and pm.pitch > 0 and row["y"] - prev["y"] > BLOCK_GAP * pm.pitch:
        return True
    return False


# ============================ CLI ============================

def default_out(fused_path: Path) -> Path:
    name = fused_path.name
    for suf in (".fused.json", ".json"):
        if name.endswith(suf):
            name = name[: -len(suf)]
            break
    return ROOT / "output" / f"{name}.md"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="book_md.py",
        description="fused.json -> 段落化 Markdown (书籍线)")
    ap.add_argument("fused", help="work/<名>.fused.json")
    ap.add_argument("--out", help="默认 output/<名>.md")
    ap.add_argument("--force", action="store_true",
                    help="覆盖已存在的输出文件(默认拒绝)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--keep-page-marks", dest="page_marks", action="store_true",
                   default=True, help="保留 <!-- page N --> (默认)")
    g.add_argument("--no-page-marks", dest="page_marks", action="store_false",
                   help="不输出页标记")
    ap.add_argument("--quiet", action="store_true", help="只报错, 不打统计")
    a = ap.parse_args(argv)

    fp = Path(a.fused).expanduser()
    if not fp.is_absolute():
        fp = (Path.cwd() / fp)
    if not fp.exists():
        print(f"找不到输入: {fp}", file=sys.stderr)
        return 2
    try:
        fused = json.loads(fp.read_text("utf-8"))
    except Exception as e:                       # noqa: BLE001
        print(f"读不动 {fp}: {e}", file=sys.stderr)
        return 2
    if not isinstance(fused, dict) or "pages" not in fused:
        print(f"{fp} 不像 fused.json(缺 pages 字段)", file=sys.stderr)
        return 2

    out = Path(a.out).expanduser() if a.out else default_out(fp)
    if not out.is_absolute():
        out = Path.cwd() / out
    if out.exists() and not a.force:
        print(f"拒绝覆盖已存在的文件: {out}\n"
              f"  output/ 下的 .md 可能是别的流程的输入。"
              f"确实要覆盖请显式加 --force, 或用 --out 换个路径。",
              file=sys.stderr)
        return 3

    opts = Options(page_marks=a.page_marks)
    md = to_markdown(fused, opts)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(md, encoding="utf-8")

    if not a.quiet:
        st = opts.stats
        for line in opts.report:
            print(f"  页眉判定: {line}", file=sys.stderr)
        if st["vertical_pages"]:
            print(f"  ⚠ 竖排页(本版不支持, 已原样输出): "
                  f"{st['vertical_pages']}", file=sys.stderr)
        if st.get("two_column_pages"):
            print(f"  ⚠ 疑似双栏页(已按中缝分栏, 请优先复核): "
                  f"{st['two_column_pages']}", file=sys.stderr)
        print(f"  页 {st['pages']}  原始行 {st['lines_in']}  合行后 {st['rows']}"
              f"  正文行 {st['kept_rows']}", file=sys.stderr)
        det = st.get("dropped_detail") or {}
        print(f"  丢弃 {st['dropped']} 行: "
              f"{', '.join(f'{k} {v}' for k, v in sorted(det.items())) or '无'}",
              file=sys.stderr)
        #  丢弃的**原文**: 只有计数的话, 误删在报告里完全看不见。
        for d in (st.get("dropped_lines") or [])[:60]:
            print(f"    - [{d['reason']}] p{d['page']} {d['text']!r}",
                  file=sys.stderr)
        rest = len(st.get("dropped_lines") or []) - 60
        if rest > 0:
            print(f"    - …另 {rest} 条(完整清单在 stats['dropped_lines'])",
                  file=sys.stderr)
        print(f"  标题 {st['headings']}  段落 {st['paragraphs']}"
              f"  正文 {st['chars']} 字", file=sys.stderr)
        if st["divergent"] or st["only_one_engine"]:
            print(f"  (融合标记: 双引擎分歧 {st['divergent']} 行, "
                  f"单引擎独有 {st['only_one_engine']} 行 —— 残留错误的集中区)",
                  file=sys.stderr)
        print(f"-> {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
