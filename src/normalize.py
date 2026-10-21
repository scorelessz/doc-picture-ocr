#!/usr/bin/env python3
"""
比对前的等价归一化 —— 消除「同一个字形被不同引擎读成不同字符」造成的假分歧。

实测: 剧本里的动作标记 △ 被 Vision 读成 'A'、被 RapidOCR 读成 '△',
      导致 **51.2% 的跨引擎分歧是假的** —— 内容完全相同, 只差这个符号。
      归一化后复核量直接减半。

只用于**比对**, 不改写最终输出文本(输出仍保留各引擎的原始读法,
由 canonical() 单独决定成稿用哪个形态)。
"""
import re
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 等价组: 组内字符在比对时视为同一个
EQUIV_GROUPS = [
    "△▲Δ∆AＡ^◇◆",        # 剧本动作行标记(各引擎读法不一)
    "（(",                  # 全半角括号
    "）)",
    "：:",
    "，,",
    "；;",
    "！!",
    "？?",
    "【〔[［",
    "】〕]］",
    "｛{",
    "｝}",
    "“\"＂",
    "”\"＂",
    "‘'",
    "’'",
    "—－-–",
    "…⋯‥",
]
_MAP: dict[str, str] = {}
for g in EQUIV_GROUPS:
    for ch in g:
        _MAP[ch] = g[0]


def load_extra_equiv() -> None:
    """config/equiv.txt: 每行一个等价组(组内首字符为代表)。"""
    f = ROOT / "config" / "equiv.txt"
    if not f.exists():
        return
    for raw in f.read_text("utf-8").splitlines():
        g = raw.split("#", 1)[0].strip()
        if len(g) >= 2:
            for ch in g:
                _MAP[ch] = g[0]


# 注意 ASCII '.' 也要纳入, 且必须放在 NFKC **之后**处理 ——
# NFKC 会把 '…'(U+2026) 拆成三个 ASCII 句点, 而 '⋯'(U+22EF) 不受影响,
# 于是 '……' 和 '⋯⋯' 会走上两条不同的路径, 永远比不相等。
# 要求 2 个以上, 免得把小数点、英文句点也吃掉。
_ELLIPSIS_RUN = re.compile(r"[…⋯‥•·․.]{2,}|[…⋯‥]")


def norm(text: str) -> str:
    """归一化用于比对: NFKC -> 等价字符折叠 -> 省略号折叠 -> 去空白。"""
    t = unicodedata.normalize("NFKC", text)
    t = "".join(_MAP.get(c, c) for c in t)
    t = _ELLIPSIS_RUN.sub("…", t)
    return re.sub(r"\s+", "", t)


# 行首动作标记可能被读成的字符。注意 '厶' '二' 是真汉字,
# 所以**不能**放进全局等价表 —— 只在行首、且剩余部分完全相同时才折叠。
_LEAD_MARKS = set("△▲Δ∆AＡDＤ^◇◆厶二ム人入八")


def _strip_lead(s: str) -> str:
    return s[1:] if s and s[0] in _LEAD_MARKS else s


def equiv(a: str, b: str) -> bool:
    """两行是否实质相同(仅字形/标记读法差异)。

    比 norm() 相等更宽松一档: 额外容忍行首动作标记的有无与误读,
    但**必须剩余部分完全一致**才折叠, 不会掩盖真正的内容差异。
    """
    na, nb = norm(a), norm(b)
    if na == nb:
        return True
    sa, sb = _strip_lead(na), _strip_lead(nb)
    if sa == sb and (sa != na or sb != nb):
        return True
    return False


# ---- 成稿时使用的规范形态 ----

ACTION_MARK = "△"
# 明确的标记字符: 不可能是正文, 后面跟什么都算动作行
_UNAMBIGUOUS = "△▲Δ∆◇◆"
# 歧义字符: 也可能是真正的正文(字母 A、汉字 厶/二/人),
# 必须后面跟中文才敢当标记
# D 是实测新增: Vision 把 △ 读成 D(下半部分 4 处)。
# 不会误伤场景标题「D. 土路日外」—— 那里 D 后面跟的是句点而非中文,
# canonical_action 对歧义字符要求后接中文才认作标记。
_AMBIGUOUS = "AＡDＤ^厶二ム人入八"
_ACTION_RE = re.compile(rf"^[\s{_UNAMBIGUOUS}{_AMBIGUOUS}]+")


def canonical_action(text: str) -> tuple[bool, str]:
    """判断是否动作行; 是则返回 (True, 去掉标记后的正文)。"""
    t = text.strip()
    if not t:
        return False, t
    m = _ACTION_RE.match(t)
    if not m or m.end() == 0:
        return False, t
    marks = t[:m.end()]
    body = t[m.end():].strip()

    if not body:
        # 整行只有标记(OCR 把 △ 单独切出来), 当作动作行但正文为空
        return True, ""

    if any(c in _UNAMBIGUOUS for c in marks):
        # 明确标记 —— 正文可以是数字/引号/外文, 如「△2010年春节，曼谷。」
        return True, body

    # 只有歧义字符时才要求后接中文, 避免把正文里的 'A'/'二人…' 误判
    if "一" <= body[0] <= "鿿":
        return True, body
    return False, t


load_extra_equiv()
