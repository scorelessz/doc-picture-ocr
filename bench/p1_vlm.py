#!/usr/bin/env python3
"""Phase 1 实测: 通过 OpenAI 兼容接口让一个 VLM 读页面, 与 PDF 原生文字层比, 只记数字。

运行时无关: llama-server(llama.cpp)、mlx_vlm.server、Ollama、vLLM 都暴露同一个
/v1/chat/completions, 换运行时只换 --base-url。这也是产品里 HTTPRuntime 的原型。

两种喂法(见 docs/REFACTOR_PLAN.md §2.1):
  page  整页一张图, 让模型按阅读顺序输出全文。
  line  按 P0 基准跑出的融合行框(work/bench/<名>.fused.json)逐行裁图, 一行一次请求。
        需要先跑过 bench/p0_baseline.py。

指标(全部按页累计, 去空白 + NFKC 后比):
  cer       编辑距离 / 真值字数
  ins_rate  插入数 / 真值字数   —— 模型凭空多出的字, 「编造」的上界
  del_rate  删除数 / 真值字数   —— 漏读/吞字
  sub_rate  替换数 / 真值字数
  empty_pages  模型一个字都没吐的页
  sec_per_page, server_peak_rss_mb(给了 --server-pid 才有)

识别文本不落盘、不打印。

用法:
  .venv/bin/python bench/p1_vlm.py <pdf> --name xiaomi-ocr-0-q8 \
      --base-url http://127.0.0.1:8080/v1 --model xiaomi-ocr-0 \
      --prompt-id xiaomi --mode page --pages 3,8-12,20,62,98,160,324 \
      [--server-pid 12345] [--max-side 1792]
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import re
import subprocess
import sys
import time
import unicodedata
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

import pymupdf                                   # noqa: E402
from rapidfuzz.distance import Levenshtein       # noqa: E402

from book_render import choose_dpi              # noqa: E402

#  提示词按模型族配置。page 模式要整页纯文本; line 模式只要这一行的字。
#  Xiaomi-OCR-0 的区域提示词取自官方模型卡; 其余是通用写法, 实测后再调。
PROMPTS = {
    "xiaomi": {"page": "Extract the text in the image.",
               "line": "Extract the text in the image."},
    "minicpm": {"page": "逐字识别图片中的全部文字，按阅读顺序输出纯文本。不要翻译、不要改写、不要补全、不要加任何解释。",
                "line": "逐字识别图片中的文字，只输出这些文字本身。"},
    "paddlevl": {"page": "OCR:", "line": "OCR:"},
    "generic": {"page": "Transcribe all text in this image exactly as written, in reading order. Output plain text only.",
                "line": "Transcribe the text in this image exactly. Output the text only."},
}

_MD_NOISE = re.compile(r"[#*`|>_~]|^\s*[-+]\s", re.M)
_TAGS = re.compile(r"<[^>]{1,40}>")


def canon(s: str) -> str:
    s = _TAGS.sub("", s)
    s = _MD_NOISE.sub("", s)
    return "".join(unicodedata.normalize("NFKC", s).split())


def parse_pages(spec: str, n: int) -> list[int]:
    out: list[int] = []
    for part in spec.split(","):
        if "-" in part:
            a, b = part.split("-", 1)
            out += range(int(a), min(int(b), n) + 1)
        elif part:
            out.append(int(part))
    return [p for p in dict.fromkeys(out) if 1 <= p <= n]


def png_bytes(pix: pymupdf.Pixmap, max_side: int) -> bytes:
    """按最长边缩放到 max_side 以内(VLM 自己也会缩, 先缩省带宽和预处理时间)。"""
    from PIL import Image
    img = Image.frombytes("L" if pix.n == 1 else "RGB", (pix.width, pix.height), pix.samples)
    s = max(img.size)
    if s > max_side:
        k = max_side / s
        img = img.resize((max(1, round(img.width * k)), max(1, round(img.height * k))),
                         Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def ask(base: str, model: str, prompt: str, png: bytes, max_tokens: int,
        api_key: str | None, timeout: float) -> str:
    body = {"model": model, "temperature": 0, "max_tokens": max_tokens,
            "messages": [{"role": "user", "content": [
                {"type": "image_url",
                 "image_url": {"url": "data:image/png;base64," + base64.b64encode(png).decode()}},
                {"type": "text", "text": prompt}]}]}
    req = urllib.request.Request(base.rstrip("/") + "/chat/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json",
                                          **({"Authorization": f"Bearer {api_key}"} if api_key else {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read())
    return d["choices"][0]["message"].get("content") or ""


def rss_mb(pid: int | None) -> float | None:
    if not pid:
        return None
    try:
        kb = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True,
                            text=True, timeout=5).stdout.strip()
        return round(int(kb) / 1024, 1) if kb else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--name", required=True, help="结果文件名用, 如 xiaomi-ocr-0-q8-llamacpp")
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--model", default="local")
    ap.add_argument("--api-key")
    ap.add_argument("--prompt-id", choices=sorted(PROMPTS), default="generic")
    ap.add_argument("--mode", choices=("page", "line"), default="page")
    ap.add_argument("--pages", default="3,8-12,20,62,98,160,324")
    ap.add_argument("--max-side", type=int, default=1792)
    ap.add_argument("--max-tokens", type=int, default=4096)
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--server-pid", type=int)
    ap.add_argument("--out")
    a = ap.parse_args()

    pdf = Path(a.pdf).expanduser().resolve()
    doc = pymupdf.open(pdf)
    pages = parse_pages(a.pages, doc.page_count)
    prompt = PROMPTS[a.prompt_id][a.mode]

    fused_pages = {}
    if a.mode == "line":
        fp = ROOT / "work" / "bench" / f"{pdf.stem}.fused.json"
        if not fp.exists():
            raise SystemExit(f"line 模式要先跑 bench/p0_baseline.py: 缺 {fp}")
        fused_pages = {p["page"]: p for p in json.loads(fp.read_text("utf-8"))["pages"]}

    per, peak, t_all, n_req = [], None, 0.0, 0
    for pno in pages:
        page = doc[pno - 1]
        ref = canon(page.get_text("text"))
        if a.mode == "page":
            z = choose_dpi(page) / 72.0
            pix = page.get_pixmap(matrix=pymupdf.Matrix(z, z), colorspace=pymupdf.csGRAY, alpha=False)
            crops = [png_bytes(pix, a.max_side)]
        else:
            fpage = fused_pages.get(pno, {})
            z = fpage.get("zoom") or choose_dpi(page) / 72.0
            pix = page.get_pixmap(matrix=pymupdf.Matrix(z, z), colorspace=pymupdf.csGRAY, alpha=False)
            from PIL import Image
            img = Image.frombytes("L", (pix.width, pix.height), pix.samples)
            crops = []
            for ln in fpage.get("lines", []):
                pad = 0.15 * ln["h"]
                box = (max(0, ln["x"] - pad), max(0, ln["y"] - pad),
                       min(img.width, ln["x"] + ln["w"] + pad), min(img.height, ln["y"] + ln["h"] + pad))
                buf = io.BytesIO()
                img.crop(tuple(round(v) for v in box)).save(buf, "PNG")
                crops.append(buf.getvalue())
        t0 = time.time()
        outs = []
        err = None
        for c in crops:
            try:
                outs.append(ask(a.base_url, a.model, prompt, c, a.max_tokens, a.api_key, a.timeout))
            except Exception as e:                        # noqa: BLE001
                err = f"{type(e).__name__}: {str(e)[:120]}"
                outs.append("")
            n_req += 1
            m = rss_mb(a.server_pid)
            if m is not None:
                peak = m if peak is None else max(peak, m)
        dt = time.time() - t0
        t_all += dt
        hyp = canon("".join(outs))
        ops = Levenshtein.editops(ref, hyp)
        cnt = {"insert": 0, "delete": 0, "replace": 0}
        for op in ops:
            cnt[op.tag] += 1
        per.append({"page": pno, "ref_chars": len(ref), "hyp_chars": len(hyp),
                    "ins": cnt["insert"], "del": cnt["delete"], "sub": cnt["replace"],
                    "requests": len(crops), "seconds": round(dt, 2), "error": err})
        r = per[-1]
        print(f"p{pno}: ref {r['ref_chars']} hyp {r['hyp_chars']} "
              f"cer {(r['ins'] + r['del'] + r['sub']) / max(1, r['ref_chars']):.4f} "
              f"{dt:.1f}s" + (f" ERR {err}" if err else ""), flush=True)

    gt = [r for r in per if r["ref_chars"] >= 50]
    N = max(1, sum(r["ref_chars"] for r in gt))
    tot = lambda k: sum(r[k] for r in gt)                 # noqa: E731
    out = {
        "phase": "p1", "name": a.name, "mode": a.mode, "prompt_id": a.prompt_id,
        "base_url_host": re.sub(r"^https?://([^/]+).*$", r"\1", a.base_url),
        "date": datetime.now().isoformat(timespec="seconds"),
        "source": pdf.name, "pages": [r["page"] for r in per], "max_side": a.max_side,
        "accuracy": {"ref_chars": N, "cer": round((tot("ins") + tot("del") + tot("sub")) / N, 5),
                     "ins_rate": round(tot("ins") / N, 5), "del_rate": round(tot("del") / N, 5),
                     "sub_rate": round(tot("sub") / N, 5),
                     "empty_pages": [r["page"] for r in gt if r["hyp_chars"] == 0]},
        "perf": {"seconds": round(t_all, 1), "sec_per_page": round(t_all / max(1, len(per)), 2),
                 "requests": n_req, "server_peak_rss_mb": peak},
        "per_page": per,
    }
    dst = Path(a.out or ROOT / "bench" / "results" / f"p1-{a.name}-{a.mode}.json")
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print(json.dumps({k: out[k] for k in ("name", "mode", "accuracy", "perf")}, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
