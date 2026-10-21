#!/usr/bin/env python3
"""
书籍线 · 第 3 步: 双引擎自动融合 (Vision + RapidOCR) -> work/<名>.fused.json

剧本线的 crosscheck.py 产出的是「给人看的可疑清单」, 本模块产出的是
「机器自己裁决完的成品行」—— 书籍线全自动, 没有人工回填环节, 所有分歧
必须当场判出胜负。

三条铁律(来自剧本线实测, 违反过要付代价):
  1. 单源行必须收录。只用单引擎 -> 该引擎漏识别的整行直接消失(实测丢 12 行)。
     本模块只给可疑的单源行打 flag, 不丢内容。被丢弃的只有两类, 且都计数:
       - 文本为空的检测框            -> stats["dropped_empty"]
       - 配对行的「碎片重影」        -> stats["dropped_contained"]
     后者见 _contained_host 处的注释: 它的文本已经整个在某条 both 行里,
     收录它等于把同一句话印两遍, 不是「保住内容」。
  2. 术语表在融合**之后**应用。顺序反了, 融合会把已修好的字覆盖回去。
  3. 比对前必须归一化。不归一化时 79% 的分歧是假的(全半角标点、省略号变体之类)。
     但书籍线用的是本模块自己的 book_equiv(只认 norm() 相等), **不是**
     normalize.equiv —— 后者会连行首的「二/厶/人/A/D」一起折掉(剧本里那是 △
     动作标记的误读), 书里那是章节号, 折掉就丢章节号。见 book_equiv 处的注释。

用法:
  .venv/bin/python src/book_fuse.py work/<名>.vision.json work/<名>.rapidocr.json \
      [--glossary config/glossary.txt] [--out work/<名>.fused.json] [--force]

  两个输入 JSON 的先后顺序随意, 按文件里的 engine 字段认。
  输出文件已存在时拒绝覆盖, 除非显式 --force。

驱动直接调用:
  from book_fuse import fuse, summarize, FuseRules
  fused = fuse(vision_doc, rapid_doc, rules)      # rules 可为 None
  report = summarize(fused)                       # 人类可读的质量小结(dict)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from statistics import median

_SRC = Path(__file__).resolve().parent
if str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))
ROOT = _SRC.parent

# ---- 复用既有模块(只 import, 不修改) ----
from crosscheck import match_lines                      # 几何贪心配对
from normalize import norm                              # 归一化(全半角/省略号)
from postcheck import (                                 # 术语表 + 语言学异常
    BRACKET_PAIRS,
    CLOSERS,
    apply_glossary,
    detect_anomalies,
    load_glossary,
)

ENGINES = ("vision", "rapidocr")

# 页级字段: 原样透传给下游(嵌字层要靠 zoom/rotation 把像素换回 PDF 点)
PAGE_FIELDS = ("page", "width", "height", "pdf_width", "pdf_height",
               "zoom", "rotation", "image", "native_text")

_CJK = re.compile(r"[一-鿿㐀-䶿]")
# 中文书里「正常」会出现的字符。其余(替换符、私用区、乱码符号)按噪声计。
_PLAUSIBLE = re.compile(
    r"[一-鿿㐀-䶿　-〿＀-￯"
    r"0-9A-Za-z\s·—–‒…‘’“”、。，！？；：（）《》〈〉「」『』【】〔〕"
    r"\.,;:!?'\"()\[\]{}<>/\\\-+=%&#@*~^_|§¶†‡°±×÷]"
)


# ============================ 裁决参数 ============================

@dataclass
class FuseRules:
    """融合裁决的全部可调参数。改默认值前先看注释里的理由。"""

    # 术语表规则 [(错误变体, 正确词), ...], 由 postcheck.load_glossary 产出
    glossary: list[tuple[str, str]] = field(default_factory=list)

    # --- 打分权重(只用于「配对但不等」的分歧行) ---
    w_cjk: float = 2.0        # 中文占比。形近误读常把汉字读成拉丁/数字
    w_anom: float = 0.5       # detect_anomalies 每命中一条扣多少
    w_bracket: float = 0.4    # 括号未闭合/多余, 每处扣多少(轻罚: 跨行括号合法)
    w_noise: float = 0.3      # 不可能出现在中文书里的字符, 每个扣多少
    w_conf: float = 2.0       # RapidOCR 置信度权重
    conf_pivot: float = 0.85  # 置信度中性点: 高于它加分, 低于它扣分。
    #   Vision 的 conf 只有 0.3/0.5/1.0 三档且与对错无关(CLAUDE.md 已记),
    #   所以 Vision 一律按中性 0 计, 不给任何置信度加减分。

    # --- 截断判定 ---
    trunc_ratio: float = 0.80  # 短的一方 <= 长的一方的这个比例, 且是其前缀/后缀
    trunc_penalty: float = 5.0  # 一票否决级别的扣分, 压过其他所有项

    # --- 平手判定 ---
    tie_eps: float = 0.15
    #   分差小于它就算平手 -> 取 RapidOCR。理由:
    #   (a) RapidOCR 是本项目既有的底稿引擎(to_markdown.py、glossary.txt 的
    #       「底稿引擎 RapidOCR」注释), 术语表里的错误变体都是按它的读法整理的,
    #       取它能让术语表继续命中;
    #   (b) 它的 conf 是连续值, 下游还能据此做二次筛查, Vision 的三档 conf
    #       提供不了任何额外证据, 平手时等于没信息;
    #   (c) PP-OCRv6 是中文原生模型, 全角标点的读法更贴合中文排版。

    # --- 单源行的可疑判定 ---
    low_conf: float = 0.60     # RapidOCR 单源行低于此置信度 -> flag=low_conf
    wide_ratio: float = 2.5    # 单字宽 > 本页中位数的这个倍数
    wide_max_chars: int = 3    # 且字符数 <= 这个值 -> 疑似水印伪检测
    #   实测: 水印/装饰线会被切出一个很宽的框, 里面只认出一两个字。

    # --- 碎片重影的包含去重(见 _contained_host) ---
    contain_vov: float = 0.50  # 垂直重叠 / 两者较小的行高, 要大于它
    contain_hov: float = 0.60  # 水平重叠 / **单源行自己**的宽, 要大于它
    #   几何与文本两个条件必须同时成立。只看文本: 书里合法的重复短句
    #   (同一页里反复出现的「是」「他说」)会被当重影吃掉; 只看几何:
    #   两引擎对同一块区域给出完全不同读法时, 证据被丢掉一半。

    # --- 几何一致性 ---
    size_tol: float = 0.02     # 两引擎对同一页的像素尺寸差异上限(比例)

    @classmethod
    def coerce(cls, rules) -> "FuseRules":
        """允许驱动传 None / FuseRules / dict / 术语表 list。"""
        if rules is None:
            return cls()
        if isinstance(rules, cls):
            return rules
        if isinstance(rules, dict):
            return cls(**rules)
        if isinstance(rules, (list, tuple)):      # 当成术语表规则
            return cls(glossary=list(rules))
        raise TypeError(f"无法识别的 rules: {type(rules).__name__}")


# ============================ 打分 ============================

def _cjk_ratio(text: str) -> float:
    core = [c for c in text if not c.isspace()]
    if not core:
        return 0.0
    return sum(1 for c in core if _CJK.match(c)) / len(core)


def _noise_count(text: str) -> int:
    return sum(1 for c in text if not _PLAUSIBLE.match(c))


def _bracket_defects(text: str) -> int:
    """行内未闭合的左括号 + 多余的右括号。

    detect_anomalies 只查「跨家族混用」, 查不出缺一半; 这里补上。
    跨行括号(整句被《》包住但断成两行)会被误判, 所以权重压得很低 ——
    而且两个候选是同一行的两种读法, 这类误判在双方身上同时出现, 相减抵消。
    """
    stack, extra = [], 0
    for ch in text:
        if ch in BRACKET_PAIRS:
            stack.append(ch)
        elif ch in CLOSERS:
            if stack:
                stack.pop()
            else:
                extra += 1
    return len(stack) + extra


def score_text(text: str, conf: float, engine: str, rules: FuseRules) -> tuple[float, dict]:
    """给一个候选读法打分。分越高越可信。返回 (总分, 各项明细)。"""
    parts = {
        "cjk": rules.w_cjk * _cjk_ratio(text),
        "anomaly": -rules.w_anom * len(detect_anomalies(text)),
        "bracket": -rules.w_bracket * _bracket_defects(text),
        "noise": -rules.w_noise * _noise_count(text),
        # Vision 的三档 conf 与对错无关 -> 中性 0, 不参与加减分
        "conf": (rules.w_conf * (conf - rules.conf_pivot)
                 if engine == "rapidocr" else 0.0),
    }
    return sum(parts.values()), parts


def _truncation(a: str, b: str, rules: FuseRules) -> int:
    """明显截断判定。返回 -1 = a 被截断, 1 = b 被截断, 0 = 都不是。

    判据: 归一化后一方是另一方的前缀或后缀(OCR 既可能丢尾也可能丢头),
    且长度显著更短。只是「短」不算 —— 必须是子串, 否则两种完全不同的
    读法会被长度判胜负。
    """
    na, nb = norm(a), norm(b)
    if not na or not nb or na == nb:
        return 0
    if len(na) < len(nb) and len(na) <= rules.trunc_ratio * len(nb) \
            and (nb.startswith(na) or nb.endswith(na)):
        return -1
    if len(nb) < len(na) and len(nb) <= rules.trunc_ratio * len(na) \
            and (na.startswith(nb) or na.endswith(nb)):
        return 1
    return 0


# ---------------- 书籍线自己的「实质相同」 ----------------
#  不能直接用 normalize.equiv: 它在 norm() 之上还会折叠**行首**的 △ 动作标记,
#  而它认的标记字符里有「二」「厶」「人」「A」「D」(剧本里 Vision 把 △ 读成这些)。
#  书里行首的「二」是章节号。实测(做旧 fixture 第 4 页):
#      vision   '雪天的客人'      rapidocr '二雪天的客人'
#  equiv 判成相同 -> 取了短的那个 -> md 里章节号「二」没了, 二级标题连带掉成正文。
#  书籍线没有 △ 这种东西, 直接只认 norm() 相等, 行首差一个字一律当分歧处理。

#  行首多出来的这一个字, 像不像扫描噪点被读成了字符。像 -> 取短的;
#  是正经文字(汉字/数字/字母) -> 取长的: 行首那个字和别的字一样是内容,
#  OCR 在页边把首字吃掉比凭空造一个汉字常见。
_LEAD_NOISE = set("、。，．·•…⋯一-—_~^'\"`|/\\()（）[]【】<>《》*+:：;；!！?？$#@%&")


def _lead_extra(a: str, b: str) -> int:
    """a 比 b 恰好在**行首**多一个字符时返回 +1; 反之 -1; 其余 0。"""
    na, nb = norm(a), norm(b)
    if len(na) == len(nb) + 1 and na[1:] == nb:
        return 1
    if len(nb) == len(na) + 1 and nb[1:] == na:
        return -1
    return 0


def book_equiv(a: str, b: str) -> bool:
    """书籍线的「实质相同」: 只认 norm() 相等(全半角标点、省略号变体等)。"""
    return norm(a) == norm(b)


def adjudicate(v_line: dict, r_line: dict, rules: FuseRules) -> dict:
    """裁决一对配对上、但 equiv 不等的行。返回决策记录。"""
    vt, rt = v_line["text"], r_line["text"]
    sv, pv = score_text(vt, v_line.get("conf", 0.0), "vision", rules)
    sr, pr = score_text(rt, r_line.get("conf", 0.0), "rapidocr", rules)

    trunc = _truncation(vt, rt, rules)
    if trunc < 0:
        sv -= rules.trunc_penalty
        pv["truncated"] = -rules.trunc_penalty
    elif trunc > 0:
        sr -= rules.trunc_penalty
        pr["truncated"] = -rules.trunc_penalty

    if abs(sv - sr) < rules.tie_eps:
        winner, why = "rapidocr", f"平手(Δ={sv - sr:+.3f} < {rules.tie_eps}) -> 取底稿引擎"
    elif sv > sr:
        winner, why = "vision", f"vision 胜 (Δ={sv - sr:+.3f})"
    else:
        winner, why = "rapidocr", f"rapidocr 胜 (Δ={sr - sv:+.3f})"
    if trunc:
        why = ("rapidocr 读法被截断; " if trunc > 0 else "vision 读法被截断; ") + why

    return {
        "winner": winner, "reason": why,
        "vision": vt, "rapidocr": rt,
        "score_vision": round(sv, 3), "score_rapidocr": round(sr, 3),
        "parts_vision": {k: round(x, 3) for k, x in pv.items()},
        "parts_rapidocr": {k: round(x, 3) for k, x in pr.items()},
    }


# ============================ 融合 ============================

def _page_index(doc: dict) -> dict[int, dict]:
    return {int(p["page"]): p for p in doc.get("pages", [])}


def _clean_lines(page: dict) -> tuple[list[dict], int]:
    """去掉文本为空的检测框。返回 (有效行, 丢弃数)。"""
    kept, dropped = [], 0
    for ln in page.get("lines", []):
        if str(ln.get("text", "")).strip():
            kept.append(ln)
        else:
            dropped += 1
    return kept, dropped


def _median_char_width(lines: list[dict]) -> float:
    vals = [ln["w"] / len(ln["text"].strip())
            for ln in lines
            if ln.get("w", 0) > 0 and len(ln["text"].strip()) >= 2]
    return float(median(vals)) if vals else 0.0


def _single_flag(ln: dict, engine: str, med_cw: float, rules: FuseRules) -> str:
    """单源行的可疑判定(行本身必须收录, 这里只决定要不要打 flag)。"""
    txt = ln["text"].strip()
    if engine == "rapidocr" and float(ln.get("conf", 1.0)) < rules.low_conf:
        return "low_conf"
    # bbox 很宽但字符极少 -> 实测是水印/装饰线造成的伪检测
    if med_cw > 0 and len(txt) <= rules.wide_max_chars and ln.get("w", 0) > 0:
        if ln["w"] / len(txt) > rules.wide_ratio * med_cw:
            return "low_conf"
    return "ok"


def _geom(ln: dict) -> dict:
    return {k: ln.get(k, 0) for k in ("x", "y", "w", "h")}


# ---------------- 碎片重影(单源行与配对行重复) ----------------
#  match_lines 是 1:1 贪心配对: A 引擎的一整行只会配上 B 引擎的**一个**框。
#  B 把同一行切成两框时, 多出来的那半行就成了 only_b —— 它与配对行几何上
#  重叠、文本上被整个包含, 但按「单源行必须收录」原样收进来之后, 下游
#  book_md.cluster_rows 又按垂直重叠把它们并回同一视觉行, 按 x 拼接 ->
#  整句在 md 里复写一遍; book_pdf 把两条都嵌进文字层 -> 用户选中复制出双份。
#  嵌字自校验(取回率)是字符多重集包含判定, 重复只会让它更高, 永远报不出来。
#  实测(验收 dupscan.py): 30 页合成件 5 处、真实手机拍摄件 7 处。
ALT_SEP = " ‖ "   # 一条 both 行并进多个读法时的分隔符(alt 只是证据, 无下游消费者)


def _span_overlap(a0: float, a1: float, b0: float, b1: float) -> float:
    return max(0.0, min(a1, b1) - max(a0, b0))


def _contained_host(single: dict, both_rows: list[dict],
                    rules: FuseRules) -> dict | None:
    """单源行是不是某条 both 行的碎片重影。是 -> 返回那条 both 行。

    几何 + 文本**双条件**, 两个都满足才算:
      - 垂直重叠 > contain_vov(较小行高的比例), 水平重叠 > contain_hov(单源行自己的宽);
      - norm(单源文本) 是 norm(配对文本) 的子串。
    只认这一个方向。反过来(单源文本更长、把配对行包住)不丢 —— 那种情况
    丢掉就真的少字了, 宁可让它留着当单源行, 由下游和报告暴露。
    多条 both 行都满足时取垂直重叠最大的那条。
    """
    ts = norm(single.get("text", ""))
    sw, sh = float(single.get("w") or 0), float(single.get("h") or 0)
    if not ts or sw <= 0 or sh <= 0:
        return None
    sx, sy = float(single.get("x", 0)), float(single.get("y", 0))

    best, best_vov = None, 0.0
    for host in both_rows:
        hw, hh = float(host.get("w") or 0), float(host.get("h") or 0)
        if hw <= 0 or hh <= 0:
            continue
        hx, hy = float(host.get("x", 0)), float(host.get("y", 0))
        vov = _span_overlap(sy, sy + sh, hy, hy + hh) / min(sh, hh)
        if vov <= rules.contain_vov:
            continue
        if _span_overlap(sx, sx + sw, hx, hx + hw) / sw <= rules.contain_hov:
            continue
        if ts not in norm(host.get("text", "")):
            continue
        if vov > best_vov:
            best, best_vov = host, vov
    return best


def _merge_alt(host: dict, text: str) -> None:
    """把被丢弃的读法并进 both 行的 alt —— 证据不许消失, 只是不再独立成行。"""
    cur = host.get("alt")
    if not cur:
        host["alt"] = text
    elif text not in cur.split(ALT_SEP):
        host["alt"] = cur + ALT_SEP + text


def _check_page_geometry(page: int, vp: dict | None, rp: dict | None,
                         rules: FuseRules) -> None:
    """两引擎必须看的是同一张图, 否则几何配对毫无意义, 宁可报错也不出垃圾。"""
    if not vp or not rp:
        return
    for key in ("width", "height"):
        a, b = vp.get(key), rp.get(key)
        if not a or not b:
            continue
        if abs(a - b) > rules.size_tol * max(a, b):
            raise ValueError(
                f"第 {page} 页两引擎的图像{key}不一致: vision={a} rapidocr={b}。"
                f"坐标不在同一个尺度上, 几何配对会全错 —— 两个引擎必须跑同一批 "
                f"work/<名>/pages/*.png。")


def fuse(vision_doc: dict, rapid_doc: dict, rules=None,
         decisions: list | None = None) -> dict:
    """把两份引擎页 JSON 融合成 fused.json 的 dict(字段见 CLAUDE 契约)。

    rules: None / FuseRules / dict / 术语表 list, 见 FuseRules.coerce。
    decisions: 传一个 list 进来, 会把每条分歧的裁决明细 append 进去
               (供日志和 summarize 使用; 不写进返回的 dict, 以免污染契约字段)。
    """
    rules = FuseRules.coerce(rules)
    for doc, want in ((vision_doc, "vision"), (rapid_doc, "rapidocr")):
        got = doc.get("engine")
        if got and got != want:
            raise ValueError(f"引擎顺序反了: 期望 {want}, 实际 {got}")

    vpages, rpages = _page_index(vision_doc), _page_index(rapid_doc)
    stats = dict(pages=0, lines=0, both=0, only_vision=0, only_rapidocr=0,
                 divergent=0, low_conf=0, glossary_hits=0, dropped_empty=0,
                 dropped_contained=0)
    out_pages = []

    for pno in sorted(set(vpages) | set(rpages)):
        vp, rp = vpages.get(pno), rpages.get(pno)
        _check_page_geometry(pno, vp, rp, rules)

        vlines, vdrop = _clean_lines(vp) if vp else ([], 0)
        rlines, rdrop = _clean_lines(rp) if rp else ([], 0)
        stats["dropped_empty"] += vdrop + rdrop

        # 宽/字比的基准按**页**算 —— 页与页的扫描尺寸、字号可能不同
        med_cw = _median_char_width(vlines + rlines)

        pairs, only_v, only_r = match_lines(vlines, rlines)
        fused_lines: list[dict] = []

        for i, j in pairs:
            v, r = vlines[i], rlines[j]
            vt, rt = v["text"].strip(), r["text"].strip()
            # conf 统一取 RapidOCR 的: 只有它是连续值, 下游还能拿来筛查;
            # Vision 的三档 conf 放进来只会被误当质量信号。
            conf = round(float(r.get("conf", 0.0)), 4)

            if book_equiv(vt, rt):
                # 规则 1: 实质相同。原始串若仍有差别(全半角标点、省略号变体),
                # 用 detect_anomalies 少的那个 —— 它正好能识别「中文里夹半角
                # 标点」, 于是会自动选中排版正确的那一版; 仍打平则取 RapidOCR。
                if vt == rt:
                    text, alt = rt, None
                elif len(detect_anomalies(vt)) < len(detect_anomalies(rt)):
                    text, alt = vt, rt
                else:
                    text, alt = rt, (vt if vt != rt else None)
                geo = _geom(r if text == rt else v)
                fused_lines.append({**geo, "text": text, "conf": conf,
                                    "src": "both", "alt": alt, "flag": "ok"})
                stats["both"] += 1
                continue

            # 规则 1.5: 只差行首一个字。打分规则对这种差异不敏感(两边
            # 异常数、中文占比都一样, 只剩 conf 微差), 会随机吃掉章节号。
            le = _lead_extra(vt, rt)
            if le:
                long_t, short_t = (vt, rt) if le > 0 else (rt, vt)
                lead = norm(long_t)[0]
                keep_long = lead not in _LEAD_NOISE
                text = long_t if keep_long else short_t
                win = (v if text == vt else r)
                d = {"winner": "vision" if text == vt else "rapidocr",
                     "reason": (f"行首多一个 {lead!r}: "
                                + ("是正经文字, 取长的" if keep_long
                                   else "像噪点, 取短的")),
                     "vision": vt, "rapidocr": rt,
                     "score_vision": None, "score_rapidocr": None}
                fused_lines.append({
                    **_geom(win), "text": text.strip(), "conf": conf,
                    "src": "both",
                    "alt": (short_t if keep_long else long_t).strip(),
                    "flag": "divergent"})
                stats["both"] += 1
                stats["divergent"] += 1
                if decisions is not None:
                    decisions.append({"page": pno, **d})
                continue

            # 规则 2: 配对但不等 -> 打分裁决, 败者进 alt
            d = adjudicate(v, r, rules)
            win, lose = (v, r) if d["winner"] == "vision" else (r, v)
            fused_lines.append({
                **_geom(win),                 # bbox 跟着胜出的文本走, 二者同源
                "text": win["text"].strip(), "conf": conf,
                "src": "both", "alt": lose["text"].strip(), "flag": "divergent",
            })
            stats["both"] += 1
            stats["divergent"] += 1
            if decisions is not None:
                decisions.append({"page": pno, **d})

        # 规则 3: 单源行必须收录, 一行都不许静默丢 ——
        #   唯一的例外是碎片重影(见 _contained_host): 文本已整个在某条 both
        #   行里, 再收一遍就是把同一句话印两遍。这种并进那条 both 行的 alt,
        #   并计入 stats["dropped_contained"](计数, 不静默)。
        both_rows = [ln for ln in fused_lines if ln["src"] == "both"]
        for lines, idxs, engine, key in (
                (vlines, only_v, "vision", "only_vision"),
                (rlines, only_r, "rapidocr", "only_rapidocr")):
            for i in idxs:
                ln = lines[i]
                txt = ln["text"].strip()
                host = _contained_host(ln, both_rows, rules)
                if host is not None:
                    _merge_alt(host, txt)
                    stats["dropped_contained"] += 1
                    continue
                flag = _single_flag(ln, engine, med_cw, rules)
                fused_lines.append({**_geom(ln), "text": txt,
                                    "conf": round(float(ln.get("conf", 0.0)), 4),
                                    "src": engine, "alt": None, "flag": flag})
                stats[key] += 1
                if flag == "low_conf":
                    stats["low_conf"] += 1

        # 规则 5: 按 y 再按 x。纯 y 排序会把同一行里顶边差几像素的框排乱,
        # 所以先按行高折算出行带再排。
        heights = [ln["h"] for ln in fused_lines if ln.get("h", 0) > 0]
        band = max(1.0, 0.5 * (median(heights) if heights else 1.0))
        fused_lines.sort(key=lambda l: (round((l["y"] + l["h"] / 2) / band), l["x"]))

        base = vp or rp or {}
        page_out = {k: base[k] for k in PAGE_FIELDS if k in base}
        for k in PAGE_FIELDS:                      # 缺的字段从另一引擎补
            if k not in page_out:
                other = rp if base is vp else vp
                if other and k in other:
                    page_out[k] = other[k]
        page_out["page"] = pno
        page_out["lines"] = fused_lines
        out_pages.append(page_out)
        stats["pages"] += 1
        stats["lines"] += len(fused_lines)

    # 规则 4: 术语表在融合**之后**应用, 顺序反了会被覆盖回去。
    # 只改 text, 不动 alt —— alt 是「另一引擎当时读成什么」的证据, 改了就不是证据了。
    #
    # 逐条规则地调 apply_glossary(而不是一次性传整张表), 是为了记下**改了什么**:
    # 术语表是纯子串替换、无词边界、无上下文, 而书籍线没有人工校对兜底, 只给一个
    # 「命中 N 处」的计数等于查不出来(验收实测: 剧本的「大爷 <- 大谷」把一本棒球书
    # 的「大谷翔平」改成了「大爷翔平」, 报告里只显示 glossary_hits=4)。
    # 效果与 apply_glossary(text, 整张表) 完全一致: 它本来就是按表序逐条替换。
    for page in out_pages:
        for ln in page["lines"]:
            for wrong, right in rules.glossary:
                before = ln["text"]
                ln["text"], n = apply_glossary(before, [(wrong, right)])
                if not n:
                    continue
                stats["glossary_hits"] += n
                if decisions is not None:
                    # before/after 是这条规则生效**前后**的整行
                    # (同一行命中多条规则时, 逐条各记一笔, 串成改写链)
                    decisions.append({
                        "kind": "glossary", "page": page["page"],
                        "rule": f"{wrong} -> {right}",
                        "before": before, "after": ln["text"],
                        # 兼容键: decisions 里原本只有裁决记录, 老的消费者
                        # (run_books.build_report 的「自动裁决抽样」)直接取
                        # d["winner"]/["vision"]/["rapidocr"]/["reason"]。
                        # 补上这几个键, 让还没按 kind 分流的消费者不会 KeyError。
                        "winner": "glossary", "reason": f"术语表改写 {wrong} -> {right}",
                        "vision": before, "rapidocr": ln["text"],
                        "score_vision": None, "score_rapidocr": None})

    return {
        "source": vision_doc.get("source") or rapid_doc.get("source"),
        "dpi": vision_doc.get("dpi") or rapid_doc.get("dpi"),
        "engines": list(ENGINES),
        "pages": out_pages,
        "stats": stats,
    }


# ============================ 质量小结 ============================

def summarize(fused: dict, decisions: list | None = None, top: int = 12) -> dict:
    """人类可读的质量小结(只返回 dict, 不写文件)。"""
    st = fused["stats"]
    both = max(1, st["both"])
    low = [{"page": p["page"], "src": ln["src"], "conf": ln["conf"],
            "w": ln["w"], "text": ln["text"]}
           for p in fused["pages"] for ln in p["lines"] if ln["flag"] == "low_conf"]
    div_pages: dict[int, int] = {}
    for p in fused["pages"]:
        n = sum(1 for ln in p["lines"] if ln["flag"] == "divergent")
        if n:
            div_pages[p["page"]] = n

    rep = {
        "source": fused.get("source"),
        "pages": st["pages"],
        "lines": st["lines"],
        "divergent_rate": round(st["divergent"] / both, 4),
        "single_source_rate": round(
            (st["only_vision"] + st["only_rapidocr"]) / max(1, st["lines"]), 4),
        "divergent_by_page": dict(sorted(div_pages.items(),
                                         key=lambda kv: -kv[1])[:top]),
        "low_conf_count": len(low),
        "low_conf_lines": low[:top],
        "low_conf_pages": sorted({d["page"] for d in low}),
        "glossary_hits": st["glossary_hits"],
        "dropped_empty": st["dropped_empty"],
        "dropped_contained": st.get("dropped_contained", 0),
        "stats": st,
    }
    if decisions is not None:
        # decisions 里混着两类记录(裁决 / 术语表改写), 按 kind 分开 ——
        # 裁决记录没有 kind 字段, 术语表记录没有 winner 字段。
        rep["sample_decisions"] = [d for d in decisions
                                   if d.get("kind") is None][:top]
        rep["glossary_edits"] = [d for d in decisions
                                 if d.get("kind") == "glossary"]
    return rep


def print_summary(rep: dict) -> None:
    print(f"页数 {rep['pages']}   行数 {rep['lines']}")
    s = rep["stats"]
    print(f"双引擎都识别 {s['both']}   仅vision {s['only_vision']}   "
          f"仅rapidocr {s['only_rapidocr']}")
    print(f"分歧 {s['divergent']} 行  (占配对行 {rep['divergent_rate']*100:.1f}%)   "
          f"单源占全部行 {rep['single_source_rate']*100:.1f}%")
    print(f"术语表命中 {s['glossary_hits']} 处   丢弃空框 {s['dropped_empty']} 个"
          f"   丢弃碎片重影 {s.get('dropped_contained', 0)} 行")
    if rep["divergent_by_page"]:
        top = "  ".join(f"p{k}:{v}" for k, v in rep["divergent_by_page"].items())
        print(f"分歧最多的页: {top}")
    print(f"低可信行 {rep['low_conf_count']} 条", end="")
    print(f"  页码 {rep['low_conf_pages']}" if rep["low_conf_pages"] else "")
    for d in rep["low_conf_lines"]:
        print(f"   p{d['page']} [{d['src']} conf={d['conf']}] {d['text'][:40]!r}")
    for d in rep.get("sample_decisions", []):
        print(f"   p{d['page']} 裁决 -> {d['winner']}: {d['reason']}")
        print(f"      vision  : {d['vision'][:50]!r}  ({d['score_vision']})")
        print(f"      rapidocr: {d['rapidocr'][:50]!r}  ({d['score_rapidocr']})")
    ge = rep.get("glossary_edits") or []
    if ge:
        print(f"术语表改写明细 {len(ge)} 处:")
        for d in ge:
            print(f"   p{d['page']} [{d['rule']}]")
            print(f"      改前: {d['before'][:50]!r}")
            print(f"      改后: {d['after'][:50]!r}")


# ============================ CLI ============================

def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="双引擎自动融合 -> fused.json (书籍线, 无人工环节)")
    ap.add_argument("json_a", type=Path, help="work/<名>.vision.json")
    ap.add_argument("json_b", type=Path, help="work/<名>.rapidocr.json")
    #  默认不加载: config/glossary.txt 是按剧本整理的专名表(大爷 <- 大谷,
    #  半晌 <- 半酌 …), 套到任意一本书上会把本来读对的词静默改错。
    #  要用就显式给路径。驱动 run_books.py 走 fuse(..., rules) 同样是 opt-in。
    ap.add_argument("--glossary", type=Path, default=None)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--force", action="store_true", help="允许覆盖已存在的输出")
    a = ap.parse_args(argv)

    docs = {}
    for p in (a.json_a, a.json_b):
        d = _load(p)
        eng = d.get("engine")
        if eng not in ENGINES:
            raise SystemExit(f"{p}: engine 字段必须是 vision 或 rapidocr, 实为 {eng!r}")
        if eng in docs:
            raise SystemExit(f"两个输入都是 {eng}, 需要各一份")
        docs[eng] = d
    if len(docs) != 2:
        raise SystemExit("需要 vision 与 rapidocr 各一份")

    out = a.out or (ROOT / "work" /
                    f"{Path(docs['vision'].get('source', 'book')).stem}.fused.json")
    out = Path(out)
    # 约束: 已存在就拒绝写 —— work/ 和 output/ 下的旧文件是别的会话的输入
    if out.exists() and not a.force:
        raise SystemExit(f"输出已存在, 拒绝覆盖: {out}\n要覆盖请显式加 --force")

    rules = FuseRules(glossary=load_glossary(a.glossary) if a.glossary else [])
    decisions: list[dict] = []
    fused = fuse(docs["vision"], docs["rapidocr"], rules, decisions=decisions)

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(fused, ensure_ascii=False, indent=1), encoding="utf-8")

    print(f"术语表规则 {len(rules.glossary)} 条 <- {a.glossary}"
          if a.glossary else "术语表: 不启用(默认; 要用加 --glossary PATH)")
    print_summary(summarize(fused, decisions))
    print(f"-> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
