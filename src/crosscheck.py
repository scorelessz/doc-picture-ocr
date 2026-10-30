#!/usr/bin/env python3
"""两个引擎的行按几何位置配对。书籍线 book_fuse 的配对底层。"""

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
