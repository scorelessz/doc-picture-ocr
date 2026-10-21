#!/usr/bin/env python3
"""书籍线 · 第 1 步: PDF -> 页图 + 几何信息。

与剧本线(run_vision.py / run_rapidocr.py)互不干扰: 本模块只新增, 不改动任何
已有文件。剧本线用 `pdfimages` 抽内嵌原图, 书籍线改用 pymupdf 渲染, 因为:
  - 渲染能处理 /Rotate、多图拼页、矢量页, pdfimages 不能;
  - 渲染结果的坐标系和 PDF 点坐标是严格线性的(像素 = 点 × zoom),
    嵌字模块才能把 OCR 框原样叠回原 PDF。

坐标约定(整条书籍线共用, 嵌字模块依赖它)
--------------------------------------------------
  像素 = 「视觉」PDF 点 × zoom,  zoom = dpi / 72,  原点左上。
  「视觉」= 阅读器实际显示的方向, 即 page.rect(已含 /Rotate 的宽高互换),
  而不是 mediabox。渲染图就是这个方向, 所以 OCR 出来的像素坐标
  直接 ÷ zoom 就是视觉点坐标。
  页面 rotation ≠ 0 时, 视觉点 -> 原始 PDF 点要再乘 page.derotation_matrix;
  rotation 已写进 JSON 供嵌字模块使用。
  (注意: pymupdf 的 page.get_text() 返回的是**未旋转**坐标, 和这里相反,
   本模块已在 native_lines() 里用 page.rotation_matrix 统一到视觉坐标。)

分辨率
--------------------------------------------------
  默认 300 dpi。若该页内嵌图像的原生分辨率更高, 就按原生渲染 —— 项目实测
  「分辨率决定识别上限」, 下采样等于白白丢字。上限 --max-dpi(默认 600)
  以及总像素上限, 防止大开本页面爆内存。

原生文字层的质量闸门(2026-10 验收补)
--------------------------------------------------
  「有字符」不等于「字能用」: 复印机 / Acrobat / 网盘预览写过文字层的扫描件
  照样是扫描件, 只数字符数(NATIVE_MIN_CHARS)会把整本书跳过重认, 产出 100%
  垃圾正文而且没有任何告警。native_quality() 给原生文字层加三道闸门:
    - 替换符 / 私用区 / 控制字符占比(乱码层);
    - 单字重复占比(「囗囗囗…」这种占位层);
    - 页面被整幅图盖住时, 文字行数与渲染图的墨迹行带数对不上。
  命中任意一条 -> PageInfo.native_suspect=True, 打 ⚠ 并建议 --force-ocr。
  闸门只**告警**, 不自动改行为 —— 自动重认会把误判的原生书白跑一遍;
  要强制重认由调用方传 force_ocr=True(CLI: --force-ocr)。

用法:
  .venv/bin/python src/book_render.py <pdf> [--dpi 300] [--color]
        [--outdir DIR] [--pages 1-20] [--max-dpi 600] [--json OUT] [--force]
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator

import pymupdf

ROOT = Path(__file__).resolve().parent.parent

DEFAULT_DPI = 300
MAX_DPI = 600
#  单页像素上限。A4@600dpi ≈ 34.8 MP; 80 MP 灰度 ≈ 80 MB 缓冲, 16 GB 机器安全。
MAX_PIXELS = 80_000_000
#  原生文字层字符数阈值: 够长才算「这页本来就有字」。
#  扫描件通常是 0; 几个零星字符多半是水印/页码残留, 不能据此跳过 OCR。
NATIVE_MIN_CHARS = 50
#  只有盖住页面这么大比例的内嵌图才参与「原生分辨率」判断,
#  否则一个高分辨率小 logo 会把整页顶到 600 dpi。
MIN_IMAGE_COVERAGE = 0.40

#  原生文字层质量闸门的阈值(见模块 docstring)
NATIVE_BAD_RATIO = 0.02        # 替换符/私用区/控制字符占比
NATIVE_REPEAT_RATIO = 0.30     # 单个字符占全页字符的比例
NATIVE_LINE_MISMATCH = 0.40    # |文字行数 - 墨迹行带数| / max(两者)
INK_PROBE_DPI = 40             # 墨迹行带数用这个分辨率量, 够用且便宜
#  灰度 PNG 的经验压缩率(实测真实扫描件 0.19~0.23 B/px, 合成页更低);
#  只用于「开跑前估算磁盘占用」这一行提示, 不参与任何判定。
PNG_BYTES_PER_PX_GRAY = 0.22
PNG_BYTES_PER_PX_RGB = 0.55


@dataclass
class PageInfo:
    """一页的几何 + 产物。不持有像素数据, 可以整本放内存。"""

    index: int                 # 1 基页号
    png: Path | None           # 渲染出的页图; 未渲染(--no-render-native)时 None
    px_w: int                  # 页图宽(像素)
    px_h: int
    pt_w: float                # 视觉 PDF 点宽 = page.rect.width
    pt_h: float
    zoom: float                # 像素 / 点
    rotation: int              # 页面 /Rotate, 0/90/180/270
    native_text: bool          # True = 本来就有文字层, 不必 OCR, 也不该再嵌字
    native_lines: list[dict] = field(default_factory=list)
    dpi: float = DEFAULT_DPI   # 本页实际渲染 dpi = zoom * 72
    #  原生文字层质量闸门: True = 这层文字可疑, 建议 --force-ocr 重认
    native_suspect: bool = False
    native_notes: list[str] = field(default_factory=list)

    def page_header(self, root: Path = ROOT) -> dict:
        """契约里的页级字段(不含 lines)。引擎模块直接拿去拼 JSON。"""
        h = {
            "page": self.index,
            "width": self.px_w,
            "height": self.px_h,
            "pdf_width": round(self.pt_w, 2),
            "pdf_height": round(self.pt_h, 2),
            "zoom": round(self.zoom, 6),
            "rotation": self.rotation,
            "image": relpath(self.png, root) if self.png else None,
            "native_text": self.native_text,
        }
        #  只在可疑时才多写两个字段: 正常书的 JSON 和原来一字不差
        if self.native_suspect:
            h["native_suspect"] = True
            h["native_notes"] = list(self.native_notes)
        return h


def relpath(p: Path | None, root: Path = ROOT) -> str | None:
    """能相对项目根就相对(契约示例是 'input/x.pdf' 这种), 否则绝对。"""
    if p is None:
        return None
    p = Path(p)
    try:
        return str(p.resolve().relative_to(root))
    except ValueError:
        return str(p)


def sort_reading_order(lines: list[dict]) -> list[dict]:
    """上到下、左到右。行高自适应分桶, 避免同一行被基线抖动拆成两桶。"""
    if not lines:
        return lines
    heights = sorted(l["h"] for l in lines if l["h"] > 0)
    med = heights[len(heights) // 2] if heights else 1.0
    bucket = max(med * 0.6, 1.0)
    return sorted(lines, key=lambda l: (round((l["y"] + l["h"] / 2) / bucket), l["x"]))


# ---------------------------------------------------------------- 分辨率

def embedded_dpi(page: pymupdf.Page) -> float | None:
    """该页内嵌图像的原生 dpi; 没有够大的图就 None。

    用面积开方算, 对图像在内容流里被转过 90° 的情况也成立
    (宽高谁对谁都不影响面积)。
    """
    page_area = page.rect.width * page.rect.height
    if page_area <= 0:
        return None
    best = None
    try:
        infos = page.get_image_info()
    except Exception:
        return None
    for info in infos:
        try:
            bbox = pymupdf.Rect(info["bbox"])
            px_w, px_h = int(info["width"]), int(info["height"])
        except (KeyError, TypeError, ValueError):
            continue
        bbox.normalize()
        pt_area = bbox.width * bbox.height
        if pt_area <= 0 or px_w <= 0 or px_h <= 0:
            continue
        if pt_area < MIN_IMAGE_COVERAGE * page_area:
            continue                      # 小图(logo/插图)不参与
        d = 72.0 * math.sqrt((px_w * px_h) / pt_area)
        best = d if best is None else max(best, d)
    return best


def choose_dpi(page: pymupdf.Page, base_dpi: float = DEFAULT_DPI,
               max_dpi: float = MAX_DPI, max_pixels: int = MAX_PIXELS,
               use_native: bool = True) -> float:
    """本页该用多少 dpi: max(base, 原生) 再夹到 max_dpi 和总像素上限内。"""
    dpi = float(base_dpi)
    if use_native:
        nat = embedded_dpi(page)
        if nat and nat > dpi:
            dpi = nat
    dpi = min(dpi, float(max_dpi))

    pt_area = page.rect.width * page.rect.height
    if pt_area > 0:
        px = pt_area * (dpi / 72.0) ** 2
        if px > max_pixels:
            dpi = 72.0 * math.sqrt(max_pixels / pt_area)
    return max(round(dpi), 1)


# ---------------------------------------------------------------- 原生文字层

def has_native_text(page: pymupdf.Page, min_chars: int = NATIVE_MIN_CHARS) -> bool:
    return len(page.get_text().strip()) >= min_chars


def image_coverage(page: pymupdf.Page) -> float:
    """最大的一幅内嵌图盖住页面的比例。扫描页 ≈ 1.0, 纯文字页 = 0。"""
    pa = page.rect.width * page.rect.height
    if pa <= 0:
        return 0.0
    best = 0.0
    try:
        infos = page.get_image_info()
    except Exception:
        return 0.0
    for info in infos:
        try:
            r = pymupdf.Rect(info["bbox"])
        except (KeyError, TypeError, ValueError):
            continue
        r.normalize()
        best = max(best, (r.width * r.height) / pa)
    return min(best, 1.0)


def ink_bands(page: pymupdf.Page, dpi: float = INK_PROBE_DPI) -> int | None:
    """渲染一张小图, 数「有墨的横向行带」有几条(≈ 版面上的文字行数)。

    阈值按本页灰度中位数自适应: 白底 255 -> 205, 发灰的扫描底 220 -> 170,
    免得把整页底噪当成墨。失败(渲染不出来)返回 None, 调用方当「没量到」。
    """
    try:
        z = max(dpi, 10.0) / 72.0
        pix = page.get_pixmap(matrix=pymupdf.Matrix(z, z),
                              colorspace=pymupdf.csGRAY, alpha=False)
    except Exception:
        return None
    w, h, stride = pix.width, pix.height, pix.stride
    if w <= 0 or h <= 0:
        return None
    buf = pix.samples
    need = max(2, int(0.01 * w))
    try:
        import numpy as np
        a = np.frombuffer(buf, dtype=np.uint8).reshape(h, stride)[:, :w]
        thr = min(220.0, max(40.0, float(np.median(a)) - 50.0))
        rows = (a < thr).sum(axis=1) >= need
        rows = rows.tolist()
    except Exception:                      # 没有 numpy 也要能跑
        counts = []
        hist = [0] * 256
        for y in range(h):
            row = buf[y * stride:y * stride + w]
            for v in row:
                hist[v] += 1
            counts.append(row)
        half, acc, med = w * h / 2, 0, 255
        for v, c in enumerate(hist):
            acc += c
            if acc >= half:
                med = v
                break
        thr = min(220.0, max(40.0, med - 50.0))
        rows = [sum(1 for v in row if v < thr) >= need for row in counts]
    bands, prev = 0, False
    for r in rows:
        if r and not prev:
            bands += 1
        prev = r
    return bands


def native_quality(page: pymupdf.Page, text_lines: int | None = None) -> dict:
    """原生文字层质量闸门。返回指标 + suspect + 人话原因。

    三条判据(任一命中即可疑):
      1) 替换符 / 私用区 / 控制字符占比 >= NATIVE_BAD_RATIO —— 乱码层;
      2) 某一个字符占全页 >= NATIVE_REPEAT_RATIO —— 「囗囗囗…」这类占位层;
      3) 页面被整幅图盖住(扫描件)且文字行数与墨迹行带数差 >= NATIVE_LINE_MISMATCH
         —— 文字层和图上的字对不上(漏行 / 整层错位 / 只有水印)。
    判据 3 只在扫描页上做(要渲染一张小图), 原生排版书直接跳过, 不花这个钱。
    """
    txt = page.get_text()
    chars = [c for c in txt if not c.isspace()]
    n = len(chars)
    bad = sum(1 for c in chars
              if c in ("�", "￼") or ord(c) < 32
              or 0xE000 <= ord(c) <= 0xF8FF
              or 0xF0000 <= ord(c) <= 0x10FFFD)
    top_char, top_n = "", 0
    if chars:
        from collections import Counter
        top_char, top_n = Counter(chars).most_common(1)[0]
    if text_lines is None:
        try:
            text_lines = sum(len(b.get("lines", []))
                             for b in page.get_text("dict").get("blocks", [])
                             if b.get("type", 0) == 0)
        except Exception:
            text_lines = 0

    cov = image_coverage(page)
    bands = ink_bands(page) if cov >= MIN_IMAGE_COVERAGE else None

    bad_ratio = bad / n if n else 0.0
    rep_ratio = top_n / n if n else 0.0
    reasons: list[str] = []
    if bad_ratio >= NATIVE_BAD_RATIO:
        reasons.append(f"文字层里 {bad_ratio:.0%} 是替换符/私用区/控制字符")
    if rep_ratio >= NATIVE_REPEAT_RATIO and n >= 20:
        reasons.append(f"「{top_char}」一个字就占了文字层的 {rep_ratio:.0%}")
    mismatch = None
    if bands is not None:
        hi = max(bands, text_lines)
        mismatch = abs(bands - text_lines) / hi if hi else 0.0
        if hi >= 3 and mismatch >= NATIVE_LINE_MISMATCH:
            reasons.append(
                f"这是扫描图, 图上量到 {bands} 行墨迹, 文字层只有 {text_lines} 行")
    return {
        "chars": n,
        "bad_ratio": round(bad_ratio, 4),
        "repeat_char": top_char,
        "repeat_ratio": round(rep_ratio, 4),
        "image_coverage": round(cov, 3),
        "text_lines": text_lines,
        "ink_bands": bands,
        "line_mismatch": round(mismatch, 3) if mismatch is not None else None,
        "suspect": bool(reasons),
        "reasons": reasons,
    }


def native_lines(page: pymupdf.Page, zoom: float) -> list[dict]:
    """原生文字层 -> 和 OCR 行同构的 [{x,y,w,h,conf,text}](像素, 视觉坐标)。

    page.get_text() 给的是未旋转坐标, 这里乘 rotation_matrix 转到视觉坐标,
    和渲染图对齐。
    """
    rot = page.rotation_matrix
    out: list[dict] = []
    try:
        blocks = page.get_text("dict").get("blocks", [])
    except Exception:
        return out
    for blk in blocks:
        if blk.get("type", 0) != 0:          # 1 = 图像块
            continue
        for ln in blk.get("lines", []):
            text = "".join(sp.get("text", "") for sp in ln.get("spans", []))
            if not text.strip():
                continue
            r = pymupdf.Rect(ln["bbox"]) * rot
            r.normalize()
            out.append({
                "x": round(r.x0 * zoom, 1),
                "y": round(r.y0 * zoom, 1),
                "w": round(r.width * zoom, 1),
                "h": round(r.height * zoom, 1),
                "conf": 1.0,
                "text": text,
            })
    return sort_reading_order(out)


# ---------------------------------------------------------------- 渲染

def page_dir(pdf: Path, outdir: Path | None = None, root: Path = ROOT) -> Path:
    return Path(outdir) if outdir else root / "work" / Path(pdf).stem / "pages"


def _parse_pages(spec: str | None, n: int) -> list[int]:
    """'3' / '2-8' / '' -> 0 基页索引列表。"""
    if not spec:
        return list(range(n))
    a, _, b = spec.partition("-")
    lo = max(1, int(a))
    hi = min(n, int(b) if b else lo)
    if lo > hi:
        raise SystemExit(f"--pages {spec} 超出范围 (共 {n} 页)")
    return list(range(lo - 1, hi))


def iter_pages(pdf: str | Path, dpi: float = DEFAULT_DPI,
               outdir: str | Path | None = None, gray: bool = True, *,
               max_dpi: float = MAX_DPI, max_pixels: int = MAX_PIXELS,
               native_min_chars: int = NATIVE_MIN_CHARS,
               force_ocr: bool = False, use_native_dpi: bool = True,
               render_native: bool = True, pages: str | None = None,
               force: bool = False, overwrite_pages: bool = False,
               native_gate: bool = True, root: Path = ROOT,
               verbose: bool = True) -> Iterator[PageInfo]:
    """逐页渲染。一次只有一页的像素在内存里, 整本书不会一起读进来。

    force_ocr=True  -> 无视原生文字层, 一律当扫描页渲染 + OCR。
    render_native=False -> 原生文字页不渲染(省时省盘), PageInfo.png 为 None。
    overwrite_pages=True -> 允许覆盖已存在的页图。页图是本线自己的临时产物,
        调用方确认这个目录归自己(book_engines 对 work/<名>/pages 就是如此)时置真;
        --resume / 中断续跑全靠它, 否则残留页图会让整份 PDF 直接失败。
    native_gate=False -> 不对原生文字层做质量检查(省掉一张小图的渲染)。
    """
    pdf = Path(pdf).expanduser().resolve()
    if not pdf.exists():
        raise SystemExit(f"文件不存在: {pdf}")
    pdir = page_dir(pdf, outdir, root)
    pdir.mkdir(parents=True, exist_ok=True)

    doc = pymupdf.open(str(pdf))
    try:
        idxs = _parse_pages(pages, doc.page_count)
        #  覆盖保护: 已存在的页图不许悄悄盖掉(work/ 下可能是别的 fork 的输入)。
        #  调用方确认这个目录是本线自己的临时页图目录时传 overwrite_pages=True。
        if not (force or overwrite_pages):
            clash = [pdir / f"pg-{i + 1:04d}.png" for i in idxs]
            clash = [p for p in clash if p.exists()]
            if clash:
                raise SystemExit(
                    f"{len(clash)} 个页图已存在, 例如 {clash[0]}\n"
                    f"拒绝覆盖。这些多半是上次运行(或 --keep-pages)留下的临时页图; "
                    f"确认里面没有要留的东西就删掉它们再跑:\n"
                    f"  rm -f {pdir}/pg-*.png\n"
                    f"确实要就地覆盖再加 --force。")

        for i in idxs:
            page = doc[i]
            nat = (not force_ocr) and has_native_text(page, native_min_chars)
            eff = choose_dpi(page, dpi, max_dpi, max_pixels, use_native_dpi)
            zoom = eff / 72.0

            png: Path | None = None
            px_w = px_h = 0
            if nat and not render_native:
                px_w = int(round(page.rect.width * zoom))
                px_h = int(round(page.rect.height * zoom))
            else:
                pix = page.get_pixmap(
                    matrix=pymupdf.Matrix(zoom, zoom),
                    colorspace=pymupdf.csGRAY if gray else pymupdf.csRGB,
                    alpha=False,
                )
                png = pdir / f"pg-{i + 1:04d}.png"
                pix.save(str(png))
                px_w, px_h = pix.width, pix.height
                pix = None                     # 尽早放掉这一页的像素

            nlines = native_lines(page, zoom) if nat else []
            info = PageInfo(
                index=i + 1, png=png, px_w=px_w, px_h=px_h,
                pt_w=page.rect.width, pt_h=page.rect.height,
                zoom=zoom, rotation=page.rotation, native_text=nat,
                native_lines=nlines,
                dpi=eff,
            )
            #  「有字符」不等于「字能用」: 给原生文字层加质量闸门
            if nat and native_gate:
                q = native_quality(page, len(nlines))
                info.native_suspect = bool(q["suspect"])
                info.native_notes = list(q["reasons"])
            if verbose:
                tag = f"原生文字 {len(info.native_lines)}行" if nat else "扫描页"
                print(f"  第{info.index}页 {px_w}x{px_h} @{eff:g}dpi "
                      f"rot={info.rotation} {tag}", file=sys.stderr)
                if info.native_suspect:
                    print(f"  ⚠ 第{info.index}页 原生文字层可疑: "
                          f"{'; '.join(info.native_notes)}\n"
                          f"    这层文字会原样进 md 和文字层。要重新识别加 --force-ocr。",
                          file=sys.stderr)
            yield info
    finally:
        doc.close()


def plan_render(pdf: str | Path, dpi: float = DEFAULT_DPI, gray: bool = True, *,
                max_dpi: float = MAX_DPI, max_pixels: int = MAX_PIXELS,
                native_min_chars: int = NATIVE_MIN_CHARS,
                force_ocr: bool = False, use_native_dpi: bool = True,
                render_native: bool = True,
                pages: str | None = None) -> dict:
    """不渲染, 只算: 要处理几页、其中几页是原生文字、页图大约占多少盘。

    用途有二: (1) 开跑前打一行磁盘预估, 别让几百页的书悄悄吃掉 1 GB;
    (2) 给进度回调一个**准确**的分母(要 OCR 的页数), 分批跑时也不会跳。
    只读元数据 + get_text, 实测 373 页真书 0.1s, 可以放心每次都做。
    """
    pdf = Path(pdf).expanduser().resolve()
    doc = pymupdf.open(str(pdf))
    try:
        idxs = _parse_pages(pages, doc.page_count)
        n_native = 0
        px_total = 0
        px_peak = 0
        dpis: list[float] = []
        for i in idxs:
            page = doc[i]
            nat = (not force_ocr) and has_native_text(page, native_min_chars)
            eff = choose_dpi(page, dpi, max_dpi, max_pixels, use_native_dpi)
            dpis.append(eff)
            if nat:
                n_native += 1
                if not render_native:
                    continue
            z = eff / 72.0
            px = int(round(page.rect.width * z)) * int(round(page.rect.height * z))
            px_total += px
            px_peak = max(px_peak, px)
        per_px = PNG_BYTES_PER_PX_GRAY if gray else PNG_BYTES_PER_PX_RGB
        return {
            "pages": len(idxs),
            "native": n_native,
            "to_ocr": len(idxs) - n_native,
            "rendered": len(idxs) - (0 if render_native else n_native),
            "pixels": px_total,
            "est_bytes": int(px_total * per_px),
            "est_bytes_per_page": int(px_peak * per_px),
            "dpi_min": min(dpis) if dpis else dpi,
            "dpi_max": max(dpis) if dpis else dpi,
        }
    finally:
        doc.close()


def human_bytes(n: float) -> str:
    for unit, step in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if n >= step:
            return f"{n / step:.1f} {unit}"
    return f"{int(n)} B"


def render_pdf(pdf: str | Path, dpi: float = DEFAULT_DPI,
               outdir: str | Path | None = None, gray: bool = True,
               **kw) -> list[PageInfo]:
    """契约 API: 渲染整本, 返回页信息列表(只有元数据, 像素都在磁盘上)。"""
    return list(iter_pages(pdf, dpi=dpi, outdir=outdir, gray=gray, **kw))


# ---------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="PDF -> 页图 + 几何信息(书籍线第 1 步)")
    ap.add_argument("pdf")
    ap.add_argument("--dpi", type=float, default=DEFAULT_DPI)
    ap.add_argument("--max-dpi", type=float, default=MAX_DPI)
    ap.add_argument("--max-pixels", type=int, default=MAX_PIXELS)
    ap.add_argument("--color", action="store_true", help="彩色渲染(默认灰度)")
    ap.add_argument("--outdir", default=None, help="页图目录, 默认 work/<名>/pages")
    ap.add_argument("--pages", default=None, help="只处理 N 或 N-M")
    ap.add_argument("--no-native-dpi", action="store_true",
                    help="不按内嵌图原生分辨率提升 dpi")
    ap.add_argument("--force-ocr", action="store_true",
                    help="无视原生文字层, 一律当扫描页")
    ap.add_argument("--no-render-native", action="store_true",
                    help="原生文字页不渲染页图")
    ap.add_argument("--no-native-gate", action="store_true",
                    help="不检查原生文字层质量(默认检查并对可疑页告警)")
    ap.add_argument("--overwrite-pages", action="store_true",
                    help="允许覆盖已存在的页图(页图是临时产物)")
    ap.add_argument("--plan", action="store_true",
                    help="只估算页数/分辨率/磁盘占用, 不渲染")
    ap.add_argument("--json", default=None, help="把页信息写到这个 JSON")
    ap.add_argument("--force", action="store_true", help="允许覆盖已存在的文件")
    a = ap.parse_args(argv)

    plan = plan_render(
        a.pdf, dpi=a.dpi, gray=not a.color, max_dpi=a.max_dpi,
        max_pixels=a.max_pixels, use_native_dpi=not a.no_native_dpi,
        force_ocr=a.force_ocr, render_native=not a.no_render_native,
        pages=a.pages,
    )
    print(f"预估: {plan['pages']} 页(原生文字 {plan['native']}), "
          f"渲染 {plan['rendered']} 张 @{plan['dpi_min']:g}~{plan['dpi_max']:g}dpi, "
          f"页图共约 {human_bytes(plan['est_bytes'])}", file=sys.stderr)
    if a.plan:
        return 0

    infos = render_pdf(
        a.pdf, dpi=a.dpi, outdir=a.outdir, gray=not a.color,
        max_dpi=a.max_dpi, max_pixels=a.max_pixels,
        use_native_dpi=not a.no_native_dpi, force_ocr=a.force_ocr,
        render_native=not a.no_render_native, pages=a.pages, force=a.force,
        overwrite_pages=a.overwrite_pages, native_gate=not a.no_native_gate,
    )
    nat = sum(1 for p in infos if p.native_text)
    print(f"共 {len(infos)} 页, 其中原生文字页 {nat}", file=sys.stderr)
    sus = [p.index for p in infos if p.native_suspect]
    if sus:
        print(f"⚠ {len(sus)} 页的原生文字层可疑(例如第{sus[0]}页), "
              f"这些页会跳过 OCR 直接用旧文字层; 要重新识别加 --force-ocr\n"
              f"  可疑页: {sus[:30]}", file=sys.stderr)

    if a.json:
        out = Path(a.json).expanduser()
        if out.exists() and not a.force:
            raise SystemExit(f"{out} 已存在, 拒绝覆盖(要盖加 --force)")
        out.parent.mkdir(parents=True, exist_ok=True)
        doc = {
            "source": relpath(Path(a.pdf).expanduser().resolve()),
            "dpi": a.dpi,
            "pages": [p.page_header() for p in infos],
        }
        out.write_text(json.dumps(doc, ensure_ascii=False, indent=1),
                       encoding="utf-8")
        print(f"-> {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
