#!/usr/bin/env python3
"""断句信 VLM 的评估: 抽查页上加/不加 VLM 段落判断。只出数字。

CER 用去空白的 md 文字对 v2 真值, 段落没有真值, 用代理指标: 段尾没有句末标点的段落占比(多半是切错了)。
要先跑 bench/p5_fuse_eval.py。结果写 bench/results/p5-breaks.json。
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))

from rapidfuzz.distance import Levenshtein       # noqa: E402

from p3_fuse_parity import norm_text             # noqa: E402

CLI = ROOT / ".build" / "release" / "ocr-cli"
BOOKS = {"en": ("work/bench/spot-en2", [3]), "zh": ("work/bench/spot-zh", [])}
END = re.compile(r"""[.!?。！？…"'”’」』)）:：]$""")


def run(fused: Path, flags: list[str], out: Path) -> dict:
    st = out.with_suffix(".stats.json")
    r = subprocess.run([str(CLI), "md", str(fused), "--out", str(out), "--stats", str(st), "--force", *flags], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr[-300:])
    return json.loads(st.read_text("utf-8"))


def score(md: Path, truth: dict, pages: list[int]) -> dict:
    text = md.read_text("utf-8")
    blocks = [b for b in text.split("\n\n")[1:] if not b.startswith("<!--") and not b.startswith("#")]
    paras = [re.sub(r"<!-- page \d+ -->", "", b).strip() for b in blocks]
    bad = sum(1 for p in paras if p and not END.search(p))
    body = norm_text(re.sub(r"<!-- page \d+ -->", "", "".join(text.split("\n\n")[1:])))
    ref = "".join(truth[p] for p in pages)
    return {"paragraphs": len(paras), "no_end_punct": bad, "no_end_rate": round(bad / max(1, len(paras)), 4),
            "edits": Levenshtein.distance(ref, body), "chars": len(ref), "cer": round(Levenshtein.distance(ref, body) / len(ref), 5)}


def main() -> int:
    w = ROOT / "work/bench/p5"
    out = {"phase": "p5", "name": "vlm-breaks", "note": "CER 含 md 删掉的页码, 只看两列的相对差"}
    for tag, (spot, ex) in BOOKS.items():
        truth = {int(k): v for k, v in json.loads((ROOT / spot / "truth.json").read_text("utf-8")).items()}
        pages = sorted(p for p in truth if p not in ex)
        d = json.loads((w / f"{tag}.fused.vlm.json").read_text("utf-8"))
        d["pages"] = [p for p in d["pages"] if p["page"] in pages]
        f = w / f"{tag}.spot.fused.json"
        f.write_text(json.dumps(d, ensure_ascii=False), "utf-8")
        a, b = run(f, [], w / f"{tag}.nobreak.md"), run(f, ["--vlm-breaks"], w / f"{tag}.break.md")
        hint = [l.get("vlm_break") for p in d["pages"] for l in p["lines"]]
        out[tag] = {"pages": pages, "geometry": score(w / f"{tag}.nobreak.md", truth, pages), "with_vlm": score(w / f"{tag}.break.md", truth, pages),
                    "overrides": b["vlm_break_overrides"], "hint_true": hint.count(True), "hint_false": hint.count(False), "hint_none": hint.count(None)}
        print(tag, out[tag]["geometry"], out[tag]["with_vlm"], {k: out[tag][k] for k in ("overrides", "hint_true", "hint_false", "hint_none")})
    (ROOT / "bench/results/p5-breaks.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
