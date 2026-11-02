#!/usr/bin/env python3
"""Phase 3 对拍: Swift 版融合(ocr-cli fuse)与 Python fused.json 逐行比, 并比较新旧去重。只出数字。

用法: .venv/bin/python bench/p3_fuse_parity.py <书名(不含 .pdf)> --tag en|zh [--spot work/bench/spot-en2]
  a) --legacy 输出 vs work/bench/<名>.fused.json: 行数, text/src/flag/alt 完全一致, 坐标与 conf 差 ≤ 0.001, stats 一致
  b) 新规则 vs legacy: 多少行被新去重、在哪几页; 给了 --spot 时用 P1 v2 真值算新旧融合 CER
结果写 bench/results/p3-fuse-<tag>.json; 融合产物落 work/bench/p3/, 不进仓库。
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))

from rapidfuzz.distance import Levenshtein       # noqa: E402

from p1_vlm import canon                        # noqa: E402

CLI = ROOT / ".build" / "release" / "ocr-cli"
TOL = 0.001
_LATEX = re.compile(r"\\[()\[\]]|\^\{|\$|(?<=\d)\}")
_QUOTES = {0x201c: '"', 0x201d: '"', 0x2018: "'", 0x2019: "'", 0x2032: "'", 0x2033: '"'}


def fuse(vision: Path, rapid: Path, out: Path, legacy: bool) -> dict:
    cmd = [str(CLI), "fuse", str(vision), str(rapid), "--out", str(out), "--force"] + (["--legacy"] if legacy else [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"ocr-cli fuse 失败: {r.stderr.strip()[:300]}")
    return json.loads(out.read_text("utf-8"))


def compare(py: dict, sw: dict) -> dict:
    res = {"pages_py": len(py["pages"]), "pages_swift": len(sw["pages"]), "stats_equal": py["stats"] == sw["stats"],
           "page_line_count_mismatch": [], "text": 0, "src": 0, "flag": 0, "alt": 0, "coord": 0, "conf": 0,
           "max_coord_diff": 0.0, "max_conf_diff": 0.0, "page_field_mismatch": 0, "lines_compared": 0,
           "pages_with_diff": []}
    if not res["stats_equal"]:
        res["stats_py"], res["stats_swift"] = py["stats"], sw["stats"]
    sp = {p["page"]: p for p in sw["pages"]}
    for pp in py["pages"]:
        q = sp.get(pp["page"])
        if q is None:
            res["page_line_count_mismatch"].append([pp["page"], len(pp["lines"]), None])
            continue
        for k in ("width", "height", "pdf_width", "pdf_height", "zoom", "rotation", "image", "native_text"):
            if pp.get(k) != q.get(k):
                res["page_field_mismatch"] += 1
        if len(pp["lines"]) != len(q["lines"]):
            res["page_line_count_mismatch"].append([pp["page"], len(pp["lines"]), len(q["lines"])])
        bad = False
        for a, b in zip(pp["lines"], q["lines"]):
            res["lines_compared"] += 1
            for k in ("text", "src", "flag", "alt"):
                if a[k] != b.get(k, "<缺键>"):
                    res[k] += 1
                    bad = True
            d = max(abs(a[k] - b[k]) for k in "xywh")
            res["max_coord_diff"] = max(res["max_coord_diff"], d)
            if d > TOL:
                res["coord"] += 1
                bad = True
            c = abs(a["conf"] - b["conf"])
            res["max_conf_diff"] = max(res["max_conf_diff"], c)
            if c > TOL:
                res["conf"] += 1
                bad = True
        if bad:
            res["pages_with_diff"].append(pp["page"])
    res["max_coord_diff"] = round(res["max_coord_diff"], 6)
    res["max_conf_diff"] = round(res["max_conf_diff"], 6)
    res["identical"] = (res["stats_equal"] and not res["page_line_count_mismatch"] and not res["pages_with_diff"]
                        and res["page_field_mismatch"] == 0 and res["pages_py"] == res["pages_swift"])
    return res


def diff_rules(old: dict, new: dict) -> dict:
    by = []
    for a, b in zip(old["pages"], new["pages"]):
        n = len(a["lines"]) - len(b["lines"])
        if n:
            by.append({"page": a["page"], "lines_removed": n})
    return {"stats_legacy": old["stats"], "stats_new": new["stats"],
            "newly_dropped": new["stats"]["dropped_contained"] - old["stats"]["dropped_contained"],
            "pages": by}


def norm_text(s: str) -> str:
    return canon(_LATEX.sub("", s)).translate(_QUOTES)


def cer(doc: dict, truth: dict[int, str], pages: list[int]) -> dict:
    by = {p["page"]: p for p in doc["pages"]}
    c = {"insert": 0, "delete": 0, "replace": 0}
    per = {}
    for p in pages:
        hyp = norm_text("".join(l["text"] for l in by[p]["lines"]))
        ops = Levenshtein.editops(truth[p], hyp)
        for o in ops:
            c[o.tag] += 1
        per[p] = len(ops)
    n = max(1, sum(len(truth[p]) for p in pages))
    t = sum(c.values())
    return {"chars": n, "edits": t, "cer": round(t / n, 5), "ins": round(c["insert"] / n, 5),
            "del": round(c["delete"] / n, 5), "sub": round(c["replace"] / n, 5), "edits_by_page": per}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("stem")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--spot")
    ap.add_argument("--exclude", default="", help="CER 另算一份时排除的页, 逗号分隔")
    a = ap.parse_args()

    w = ROOT / "work" / "bench"
    tmp = w / "p3"
    tmp.mkdir(parents=True, exist_ok=True)
    v, r = w / f"{a.stem}.vision.json", w / f"{a.stem}.rapidocr.json"
    py = json.loads((w / f"{a.stem}.fused.json").read_text("utf-8"))
    legacy = fuse(v, r, tmp / f"{a.tag}-legacy.fused.json", True)
    new = fuse(v, r, tmp / f"{a.tag}-new.fused.json", False)

    out = {"phase": "p3", "source": a.stem, "legacy_vs_python": compare(py, legacy), "new_vs_legacy": diff_rules(legacy, new)}
    if a.spot:
        truth = {int(k): v_ for k, v_ in json.loads((ROOT / a.spot / "truth.json").read_text("utf-8")).items()}
        ps = sorted(truth)
        out["cer"] = {"pages": ps, "legacy": cer(legacy, truth, ps), "new": cer(new, truth, ps)}
        ex = {int(x) for x in a.exclude.split(",") if x}
        if ex:
            sub = [p for p in ps if p not in ex]
            out["cer_excl"] = {"excluded": sorted(ex), "pages": sub,
                               "legacy": cer(legacy, truth, sub), "new": cer(new, truth, sub)}
    dst = ROOT / "bench" / "results" / f"p3-fuse-{a.tag}.json"
    dst.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0 if out["legacy_vs_python"]["identical"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
