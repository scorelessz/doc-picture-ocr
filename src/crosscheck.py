#!/usr/bin/env python3
"""
阶段 3: 多引擎交叉验证 —— 核心组件

把各引擎的标准化 JSON 按行对齐, 做字符级 diff, 产出「可疑清单」。
一致处几乎不可能同时错; 分歧处即错误定位信号。

用法:
  .venv/bin/python src/crosscheck.py work/A.vision.json work/B.rapidocr.json \
      [--out work/A.crosscheck.json]
"""
import json
import sys
from difflib import SequenceMatcher
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from normalize import norm, equiv

ROOT = Path(__file__).resolve().parent.parent

# 行匹配阈值: 垂直中心距离 < 行高的这个比例, 且水平有重叠
VERT_TOL = 0.6


def vertical_overlap(a: dict, b: dict) -> float:
    top = max(a["y"], b["y"])
    bot = min(a["y"] + a["h"], b["y"] + b["h"])
    inter = max(0.0, bot - top)
    return inter / max(1e-6, min(a["h"], b["h"]))


def horizontal_overlap(a: dict, b: dict) -> float:
    left = max(a["x"], b["x"])
    right = min(a["x"] + a["w"], b["x"] + b["w"])
    inter = max(0.0, right - left)
    return inter / max(1e-6, min(a["w"], b["w"]))


def match_lines(la: list[dict], lb: list[dict]) -> tuple[list, list, list]:
    """贪心按几何位置匹配两个引擎的行。返回 (配对, A独有, B独有)。"""
    used_b: set[int] = set()
    pairs = []
    for i, a in enumerate(la):
        best, best_score = -1, 0.0
        for j, b in enumerate(lb):
            if j in used_b:
                continue
            v = vertical_overlap(a, b)
            h = horizontal_overlap(a, b)
            if v < VERT_TOL or h <= 0:
                continue
            score = v + h
            if score > best_score:
                best, best_score = j, score
        if best >= 0:
            used_b.add(best)
            pairs.append((i, best))
    only_a = [i for i in range(len(la)) if i not in {p[0] for p in pairs}]
    only_b = [j for j in range(len(lb)) if j not in used_b]
    return pairs, only_a, only_b


def diff_spans(sa: str, sb: str) -> list[dict]:
    """字符级差异片段。"""
    spans = []
    for tag, i1, i2, j1, j2 in SequenceMatcher(None, sa, sb, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        spans.append({
            "op": tag,
            "a_pos": i1, "a": sa[i1:i2],
            "b_pos": j1, "b": sb[j1:j2],
        })
    return spans


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    pa, pb = Path(sys.argv[1]), Path(sys.argv[2])
    da, db = json.loads(pa.read_text("utf-8")), json.loads(pb.read_text("utf-8"))
    ea, eb = da["engine"], db["engine"]

    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv \
        else ROOT / "work" / f"{Path(da['source']).stem}.crosscheck.json"

    all_items = []
    tot = dict(lines_a=0, lines_b=0, matched=0, agree=0, disagree=0,
               only_a=0, only_b=0, diff_chars=0, chars_a=0)

    for pa_, pb_ in zip(da["pages"], db["pages"]):
        la, lb = pa_["lines"], pb_["lines"]
        tot["lines_a"] += len(la)
        tot["lines_b"] += len(lb)
        tot["chars_a"] += sum(len(l["text"]) for l in la)

        # 行高中位数: 用来给裁切框封顶。OCR 偶尔会把某行的检测框
        # 框超(实测有行报 110px 而全页中位数只有 68px), 不封顶的话
        # 裁出来是两三行, 人分不清哪行才是当前条目。
        _hs = sorted(l["h"] for l in la + lb)
        med_h = _hs[len(_hs) // 2] if _hs else 60.0

        pairs, only_a, only_b = match_lines(la, lb)
        tot["matched"] += len(pairs)
        tot["only_a"] += len(only_a)
        tot["only_b"] += len(only_b)

        for i, j in pairs:
            a, b = la[i], lb[j]
            # 归一化后再比 —— 实测 51% 的分歧只是 △ 被读成 A 之类的
            # 等价字形差异, 内容完全相同, 不该占用人工复核预算。
            if equiv(a["text"], b["text"]):
                tot["agree"] += 1
                continue
            tot["disagree"] += 1
            spans = diff_spans(a["text"], b["text"])
            tot["diff_chars"] += sum(max(len(s["a"]), len(s["b"])) for s in spans)
            # 供校对界面裁图。横向取并集(两边内容都要看全);
            # 纵向**不能**取并集 —— 两引擎的行框常有垂直偏移, 并集会
            # 拉高到两行, 让人分不清哪行才是当前条目。改为以行中心为准、
            # 按较小的行高收紧。
            x0 = min(a["x"], b["x"])
            x1 = max(a["x"] + a["w"], b["x"] + b["w"])
            cy = (a["y"] + a["h"] / 2 + b["y"] + b["h"] / 2) / 2
            lh = min(min(a["h"], b["h"]) * 1.35, med_h * 1.6)
            all_items.append({
                "page": pa_["page"], "image": pa_["image"],
                "crop": [round(x0) - 8, round(cy - lh / 2),
                         round(x1 - x0) + 16, round(lh)],
                "kind": "disagree",
                ea: a["text"], eb: b["text"],
                f"{ea}_conf": a["conf"], f"{eb}_conf": b["conf"],
                "spans": spans,
            })

        for i in only_a:
            a = la[i]
            all_items.append({
                "page": pa_["page"], "image": pa_["image"],
                "crop": [round(a["x"]) - 8, round(a["y"]) - 8,
                         round(a["w"]) + 16, round(a["h"]) + 16],
                "kind": f"only_{ea}", ea: a["text"], eb: "",
                f"{ea}_conf": a["conf"], "spans": [],
            })
        for j in only_b:
            b = lb[j]
            all_items.append({
                "page": pa_["page"], "image": pa_["image"],
                "crop": [round(b["x"]) - 8, round(b["y"]) - 8,
                         round(b["w"]) + 16, round(b["h"]) + 16],
                "kind": f"only_{eb}", ea: "", eb: b["text"],
                f"{eb}_conf": b["conf"], "spans": [],
            })

    doc = {"source": da["source"], "engines": [ea, eb],
           "summary": tot, "items": all_items}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")

    # ---- 报告 ----
    m, ag, dis = tot["matched"], tot["agree"], tot["disagree"]
    print(f"引擎: {ea}  vs  {eb}")
    print(f"行数: {tot['lines_a']} / {tot['lines_b']}   匹配 {m}"
          f"   仅{ea} {tot['only_a']}   仅{eb} {tot['only_b']}")
    print(f"匹配行中: 一致 {ag}  分歧 {dis}"
          f"  ({dis/max(1,m)*100:.1f}% 的行需要人看)")
    print(f"分歧字符 {tot['diff_chars']} / 总字符 {tot['chars_a']}"
          f"  = {tot['diff_chars']/max(1,tot['chars_a'])*100:.2f}%")
    print(f"可疑条目共 {len(all_items)} 条 -> {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
