#!/usr/bin/env python3
"""
书籍线 · 嵌字: fused.json + 原 PDF -> output/<名>.searchable.pdf

原页面内容一字不动(图像不重编码、不缩放、不换位), 只在每页叠一层
render_mode=3 的隐形文字层, 让 PDF 可搜索、可复制、可被下游工具取文。

用法:
    .venv/bin/python src/book_pdf.py <源.pdf> work/<名>.fused.json \\
        [--out output/<名>.searchable.pdf] [--force] [--force-text] \\
        [--min-retrieval 0.98] [--probe 200] [--probe-per-page 2]
        [--subset|--no-subset] [--quiet]

    默认输出 output/<源文件名>.searchable.pdf; **已存在就拒绝写**, 除非 --force。

作模块用:
    from book_pdf import embed, Options
    stats = embed(src_pdf, fused, out=None, opts=Options(...))   # fused: 路径或 dict

----------------------------------------------------------------------------
自校验口径(2026-10 验收改)
----------------------------------------------------------------------------
* stats["retrieval"] 是**逐行**字符取回率: 每一行的字必须出现在它**自己 bbox 的
  邻域**里(并先扣掉源 PDF 同一邻域内本来就有的字), 不是旧的「整页字符多重集包含」。
  旧口径不看位置、不看条数, 整层错位照样 1.0000 —— 实测把 /Rotate 90 页的变换
  故意弄坏, 旧口径报 0.9865, 新口径报 0.3716(行级 0.2222)。
* stats["line_retrieval"] = 整行字一个不缺地落在自己邻域内的行数占比。
* **一行都没嵌进去时 retrieval 是 None**(不是 1.0), warnings 里会有
  「本书未识别出任何文字」。下游格式化前必须判 None。
* 定位抽查按页采样: 每页 probe_per_page 条, 全书上限 probe 条(旧做法是全书 12 条,
  400 页的书 30 多页才抽到 1 条)。

----------------------------------------------------------------------------
坐标系与旋转(实测结论, 改这段代码前先读完)
----------------------------------------------------------------------------
* fused.json 的 x/y/w/h 是**显示空间**像素, 原点左上。它来自
  page.get_pixmap(matrix=Matrix(zoom, zoom)), 而 get_pixmap 已经把 /Rotate 应用过了,
  所以这套坐标对应的是 page.rect(旋转后的显示矩形), 不是 mediabox。
  点 = 像素 / zoom; 本模块实际用 page.rect 尺寸 ÷ 记录的像素尺寸求比例, 更抗 dpi 取整误差。

* TextWriter 不认识 page.rotation。它只在内容流里补一个平移, 不补旋转
  (见 pymupdf/__init__.py 的 TextWriter.write_text: 只有 "1 0 0 1 cx cy cm")。
  直接写 -> 文字按**未旋转**的内容空间摆放, 和图上的字错位。
  实测可行解: 先 page.set_rotation(0), 再给 write_text 传

      matrix = Fu * derot * Fu
      Fu    = Matrix(1, 0, 0, -1, 0, 未旋转页高)      # fz(y下) <-> pdf(y上) 翻转
      derot = 还没改 rotation 时取的 page.derotation_matrix

  写完再 set_rotation 还原。用可见红字渲染后量墨迹 bbox: /Rotate 90/180/270 三种
  页面的角点偏差都 <= 1.9pt, 和未旋转页的基线偏差完全相同。
  (不传 matrix: 实测偏差 59~143pt, 文字还会躺倒。)

  【集成裁决 2026-10-17】渲染模块那边曾得出相反结论(「视觉坐标可以直接喂
  TextWriter(page.rect), 不需要 derotation」), 依据是 search_for 在 rot=270 页和
  rot=0 页返回相同坐标 —— 那恰恰是下一条说的陷阱: 相同的**未旋转**坐标意味着显示
  位置差了一个旋转。用可见红字量墨迹复核(scratchpad/arb_rotation.py), 同一份
  fused.json 两种策略跑同一个 /Rotate 90 页:
      本模块(derot)  角点偏差 3.5pt   ←  与同份文件 rot=0 页的 2.3~4.8pt 同量级
      不 derot       角点偏差 196.1pt
  结论: derotation 留在本模块, 上游**只给显示空间坐标, 不要自己转**。两边都做会转两次。
  旋转 × CropBox 叠加也复核过(scratchpad/ink_check.py, 8 种组合):
  90/180/270 + CropBox 偏差 1.0~2.8pt, 和无 crop 无旋转的基线 1.8pt 同量级, 两个修正不打架。

* 反过来, page.search_for() / page.get_text() 在旋转页上返回的是**未旋转**坐标。
  自校验必须先乘 page.rotation_matrix 再跟 OCR 的显示空间 bbox 比。
  (不乘: 实测平均偏差 269~485pt, 会把正确的嵌字误报成全错。)

* CropBox: PyMuPDF 的 TextWriter 自己补的那个平移量取错了轴(见 _cropbox_fix),
  裁切上下不对称的页会整层纵移。本模块额外乘一个平移补回来; 实测上留白 30/下留白 60
  的页由偏 30.6pt 回到 0.6pt。

* 字体体积: 一页的 Droid Sans Fallback 全字库会让文件涨到约 1.9MB, 且与页数无关
  (garbage=4 会把各页重复的字体流合并成一份)。doc.subset_fonts() 在本机
  **不需要 fontTools**(MuPDF 自带子集化), 实测 20 页 1879KB -> 235KB。
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional, Union

import pymupdf

ROOT = Path(__file__).resolve().parent.parent

FONT_NAME = "china-ss"          # Droid Sans Fallback, 覆盖简繁中文
HEIGHT_RATIO = 0.95             # 字号初值 = bbox 高 × 此值
BASELINE_RATIO = 0.84           # 基线 y = bbox 顶 + bbox 高 × 此值
MIN_FONTSIZE = 0.5
MAX_FONTSIZE = 1000.0

DEFAULT_MIN_RETRIEVAL = 0.98
DEFAULT_PROBE = 200              # search_for 抽查**总**条数上限
DEFAULT_PROBE_PER_PAGE = 2       # 每页抽查几条(全书上限仍受 probe 约束)
#  行级取回: 判定「这一行的字出现在它自己 bbox 附近」时, bbox 往外放宽多少
#  (按行高的倍数)。字号是按 bbox 宽度反算的, 个别行的字形会略微出框。
LINE_PAD_RATIO = 0.6


@dataclass
class Options:
    force: bool = False              # 目标已存在时允许覆盖
    force_text: bool = False         # native_text 的页也强行嵌字
    subset: Optional[bool] = None    # None = 自动(源文档无原生文字层时才子集化)
    min_retrieval: float = DEFAULT_MIN_RETRIEVAL
    probe: int = DEFAULT_PROBE       # search_for 抽查条数上限(全书)
    probe_per_page: int = DEFAULT_PROBE_PER_PAGE
    verbose: bool = True


def _as_options(opts: Union[Options, dict, None]) -> Options:
    if opts is None:
        return Options()
    if isinstance(opts, Options):
        return opts
    if isinstance(opts, dict):
        known = {f for f in Options.__dataclass_fields__}
        unknown = set(opts) - known
        if unknown:
            raise TypeError(f"未知选项: {sorted(unknown)}")
        return Options(**opts)
    raise TypeError(f"opts 类型不支持: {type(opts)!r}")


def _load_fused(fused: Union[str, Path, dict]) -> dict:
    if isinstance(fused, dict):
        return fused
    p = Path(fused).expanduser()
    if not p.is_file():
        raise FileNotFoundError(f"找不到 fused JSON: {p}")
    return json.loads(p.read_text(encoding="utf-8"))


def _page_scale(pj: dict, disp: pymupdf.Rect, pno: int, warn: list) -> tuple[float, float]:
    """像素 -> PDF 点 的比例。优先用记录的像素尺寸反推, 退回 1/zoom。"""
    px_w = float(pj.get("width") or 0)
    px_h = float(pj.get("height") or 0)
    zoom = float(pj.get("zoom") or 0)

    if px_w > 0 and px_h > 0:
        sx, sy = disp.width / px_w, disp.height / px_h
        if zoom > 0:
            ref = 1.0 / zoom
            if ref > 0 and (abs(sx / ref - 1) > 0.02 or abs(sy / ref - 1) > 0.02):
                warn.append(
                    f"第{pno}页: 像素尺寸反推的比例 ({sx:.5f},{sy:.5f}) 与 zoom 推出的 "
                    f"{ref:.5f} 差 >2%; 按像素尺寸走, 请核对 fused.json 的 width/height"
                )
        if abs(sx / sy - 1) > 0.01:
            warn.append(f"第{pno}页: x/y 比例不一致 ({sx:.5f} vs {sy:.5f}), 页面可能被非等比渲染")
        return sx, sy

    if zoom > 0:
        return 1.0 / zoom, 1.0 / zoom

    warn.append(f"第{pno}页: 既无 width/height 也无 zoom, 按 1 像素=1 点处理")
    return 1.0, 1.0


def _rot_matrix(derot: pymupdf.Matrix, unrot: pymupdf.Rect) -> pymupdf.Matrix:
    """旋转页的内容流变换: 把显示空间的落笔点搬回未旋转内容空间, 并带上字形旋转。"""
    flip = pymupdf.Matrix(1, 0, 0, -1, 0, unrot.height)
    return flip * derot * flip


def _cropbox_fix(page: pymupdf.Page) -> Optional[pymupdf.Matrix]:
    """补偿 PyMuPDF TextWriter 在带 CropBox 的页上用错的平移量。

    TextWriter.write_text 会往内容流里补 "1 0 0 1 cb.x (cb.y + mb.y0) cm", 其中
    cb = page.cropbox_position 是 **fz 坐标**(y 自 mediabox 顶向下)的 CropBox 左上角;
    但内容流需要的是 CropBox 在 PDF 空间(y 向上)的**左下角**。两者只有在 CropBox
    上下留白相等时才碰巧相等 —— 书籍扫描件常见的非对称裁切会让整层文字整体纵移。

    实测(mediabox 420x595): 上留白 30/下留白 35 -> 偏 5.3pt; 上 30/下 60 -> 偏 30.6pt;
    上下都是 30 -> 0.6pt(基线噪声)。

    差值 = mediabox 高 - (cb.y0 + cb.y1)。返回的平移矩阵要**接在旋转矩阵之后**,
    因为它和 TextWriter 自己那个平移同为平移、可以交换位置。
    """
    mb, cb = page.mediabox, page.cropbox
    dy = mb.height - (cb.y0 + cb.y1)
    if abs(dy) < 1e-6:
        return None
    return pymupdf.Matrix(1, 0, 0, 1, 0, dy)


def _snippet(text: str) -> str:
    """抽查用的片段: 取中段至多 8 个字符。

    不能把行内空白挤掉 —— 嵌进去的是原文, "第一章 灯下的来信" 挤成
    "第一章灯下的来信" 后 search_for 永远搜不到, 会假报一条未命中。
    """
    core = text.strip()
    if len(core) < 2:
        return ""
    if len(core) <= 8:
        return core
    start = (len(core) - 8) // 2
    return core[start:start + 8].strip()


def _center(r) -> pymupdf.Point:
    r = pymupdf.Rect(r)
    return pymupdf.Point((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2)


def _subrect(box: pymupdf.Rect, text: str, snip: str,
             font: pymupdf.Font, fs: float) -> pymupdf.Rect:
    """片段 snip 在整行 box 里**应该**占的子矩形(按字宽比例切)。"""
    core = text.strip()
    start = core.find(snip)
    try:
        full = font.text_length(core, fs)
        pre = font.text_length(core[:start], fs) if start > 0 else 0.0
        mid = font.text_length(snip, fs)
    except Exception:
        full = 0.0
    if start < 0 or full <= 0:
        return pymupdf.Rect(box)
    x0 = box.x0 + box.width * pre / full
    x1 = min(box.x1, x0 + box.width * mid / full)
    return pymupdf.Rect(x0, box.y0, max(x1, x0 + 1e-3), box.y1)


def embed(
    src_pdf: Union[str, Path],
    fused: Union[str, Path, dict],
    out: Union[str, Path, None] = None,
    opts: Union[Options, dict, None] = None,
) -> dict:
    """把 fused.json 的行作为隐形文字层叠到 src_pdf 上, 写出可搜索 PDF。返回 stats。"""
    opts = _as_options(opts)
    src = Path(src_pdf).expanduser().resolve()
    if not src.is_file():
        raise FileNotFoundError(f"找不到源 PDF: {src}")

    data = _load_fused(fused)
    out_path = Path(out).expanduser() if out else ROOT / "output" / f"{src.stem}.searchable.pdf"
    out_path = out_path.resolve()
    if out_path == src:
        raise ValueError("输出路径不能等于源 PDF")
    if out_path.exists() and not opts.force:
        raise FileExistsError(f"{out_path} 已存在; 要覆盖请加 --force")

    warn: list[str] = []
    pages_json: dict[int, dict] = {}
    for pj in data.get("pages", []):
        try:
            pages_json[int(pj["page"])] = pj
        except (KeyError, TypeError, ValueError):
            warn.append("fused.json 里有缺少合法 page 号的页, 已跳过")

    doc = pymupdf.open(src)
    try:
        font = pymupdf.Font(FONT_NAME)
        n_pages = doc.page_count
        if set(pages_json) - set(range(1, n_pages + 1)):
            warn.append(f"fused.json 有超出 PDF 页数({n_pages})的页号, 已忽略")

        stats_pages: list[dict] = []
        embedded_boxes: dict[int, list[tuple[pymupdf.Rect, str]]] = {}
        n_embedded = n_native_skip = n_no_json = n_empty = 0
        n_lines_in = n_lines_written = n_lines_dropped = 0
        n_rotated = 0
        any_native = False

        for pno in range(n_pages):
            page = doc[pno]
            pj = pages_json.get(pno + 1)
            if pj is None:
                n_no_json += 1
                warn.append(f"第{pno + 1}页: fused.json 里没有这一页, 不嵌字")
                continue

            if "native_text" in pj:
                native = bool(pj["native_text"])
            else:
                native = bool(page.get_text().strip())
            any_native = any_native or native
            if native and not opts.force_text:
                n_native_skip += 1
                continue

            raw_lines = pj.get("lines") or []
            n_lines_in += len(raw_lines)

            disp = pymupdf.Rect(page.rect)          # 显示空间矩形
            rot = page.rotation
            derot = pymupdf.Matrix(page.derotation_matrix)   # 必须在改 rotation 前取
            if rot:
                n_rotated += 1
            if "rotation" in pj and pj["rotation"] is not None and int(pj["rotation"]) != rot:
                warn.append(
                    f"第{pno + 1}页: fused.json 记录 rotation={pj['rotation']}, "
                    f"PDF 实际是 {rot}; 按 PDF 实际值处理"
                )

            sx, sy = _page_scale(pj, disp, pno + 1, warn)

            # 先把所有行换算到显示空间的点坐标, 再决定怎么落笔
            placed: list[tuple[pymupdf.Rect, str, float]] = []
            for ln in raw_lines:
                text = (ln.get("text") or "").strip()
                if not text:
                    n_lines_dropped += 1
                    continue
                try:
                    X = float(ln["x"]) * sx
                    Y = float(ln["y"]) * sy
                    W = float(ln["w"]) * sx
                    H = float(ln["h"]) * sy
                except (KeyError, TypeError, ValueError):
                    n_lines_dropped += 1
                    warn.append(f"第{pno + 1}页: 有行缺少合法 x/y/w/h, 已跳过")
                    continue
                if not (math.isfinite(X) and math.isfinite(Y) and W > 0 and H > 0):
                    n_lines_dropped += 1
                    continue

                fs = H * HEIGHT_RATIO
                try:
                    length = font.text_length(text, fs)
                except Exception:
                    length = 0.0
                if length > 0:
                    fs *= W / length
                if not math.isfinite(fs) or fs <= 0:
                    n_lines_dropped += 1
                    continue
                fs = min(max(fs, MIN_FONTSIZE), MAX_FONTSIZE)
                placed.append((pymupdf.Rect(X, Y, X + W, Y + H), text, fs))

            if not placed:
                n_empty += 1
                continue

            if rot:
                page.set_rotation(0)
            unrot = page.rect
            matrix = _rot_matrix(derot, unrot) if rot else None
            fix = _cropbox_fix(page)
            if fix is not None:
                matrix = fix if matrix is None else matrix * fix

            writer = pymupdf.TextWriter(unrot)
            wrote = 0
            for box, text, fs in placed:
                try:
                    writer.append(
                        pymupdf.Point(box.x0, box.y0 + box.height * BASELINE_RATIO),
                        text, font=font, fontsize=fs,
                    )
                    wrote += 1
                except Exception as exc:                      # 个别字形写不进去不该炸掉整本书
                    n_lines_dropped += 1
                    warn.append(f"第{pno + 1}页: 一行写入失败({type(exc).__name__}), 已跳过")
            if wrote:
                writer.write_text(page, render_mode=3, matrix=matrix)
            if rot:
                page.set_rotation(rot)

            n_lines_written += wrote
            n_embedded += 1
            embedded_boxes[pno] = list(placed)
            stats_pages.append({"page": pno + 1, "lines": wrote, "rotation": rot})

        subset = (not any_native) if opts.subset is None else bool(opts.subset)
        if opts.subset is None and any_native:
            warn.append(
                "源文档已有原生文字层, 自动跳过 subset_fonts(免得动到原有字体); "
                "体积会多出约 1.6MB, 确认可以子集化就加 --subset"
            )
        subset_done = False
        if subset and n_embedded:
            try:
                doc.subset_fonts(verbose=False)
                subset_done = True
            except Exception as exc:
                warn.append(f"subset_fonts 失败({type(exc).__name__}: {exc}), 体积会偏大")

        out_path.parent.mkdir(parents=True, exist_ok=True)
        part = out_path.with_name(out_path.name + ".part")
        doc.save(str(part), garbage=4, deflate=True)
    finally:
        doc.close()

    try:
        check = _verify(part, src, embedded_boxes, font, opts, warn)
        part.replace(out_path)
    except Exception:
        part.unlink(missing_ok=True)
        raise

    size_in = src.stat().st_size
    size_out = out_path.stat().st_size
    stats = {
        "source": str(src),
        "out": str(out_path),
        "pages": n_pages,
        "pages_embedded": n_embedded,
        "pages_skipped_native": n_native_skip,
        "pages_skipped_no_json": n_no_json,
        "pages_skipped_empty": n_empty,
        "pages_rotated": n_rotated,
        "lines_in": n_lines_in,
        "lines_written": n_lines_written,
        "lines_dropped": n_lines_dropped,
        "force_text": opts.force_text,
        "subset_fonts": subset_done,
        "size_in": size_in,
        "size_out": size_out,
        "size_ratio": round(size_out / size_in, 4) if size_in else None,
        "per_page": stats_pages,
        "warnings": warn,
    }
    stats.update(check)
    if opts.verbose:
        _report(stats)
    return stats


def _page_chars(page: pymupdf.Page) -> list[tuple[pymupdf.Point, str]]:
    """该页每个字符的中心 + 字符本身, 统一到**显示空间**(和 OCR 的 bbox 同坐标)。

    逐**字符**而不是逐词: 中文行里没有空格, get_text('words') 会把整个可视行
    并成一个 "词", 它的中心只落在一个地方 —— 同一行里的短片段(fuse 把一行
    拆成两框时产生的那种)就会因为"词心不在我的邻域里"而整条判丢, 反过来
    一个长词也可能替邻行顶数。rawdict 给的是每个字自己的 bbox, 归属是准的。
    rawdict 在旋转页上同样返回未旋转坐标, 必须乘 rotation_matrix。
    实测 12 页真书 0.02s, 可以每页都做。rawdict 取不到时退回 words。
    """
    rm = pymupdf.Matrix(page.rotation_matrix) if page.rotation else None
    out: list[tuple[pymupdf.Point, str]] = []
    try:
        raw = page.get_text("rawdict")
    except Exception:
        raw = None
    if raw:
        for blk in raw.get("blocks", []):
            for ln in blk.get("lines", []):
                for sp in ln.get("spans", []):
                    for ch in sp.get("chars", []):
                        t = ch.get("c", "")
                        if not t or t.isspace():
                            continue
                        try:
                            r = pymupdf.Rect(ch["bbox"])
                        except (KeyError, TypeError, ValueError):
                            continue
                        if rm is not None:
                            r = r * rm
                        r.normalize()
                        out.append(
                            (pymupdf.Point((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2), t))
        return out
    #  退路: 没有 rawdict 就按词心归属(精度差一点, 但不至于没有校验)
    try:
        words = page.get_text("words")
    except Exception:
        return out
    for w in words:
        try:
            r = pymupdf.Rect(w[0], w[1], w[2], w[3])
        except Exception:
            continue
        if rm is not None:
            r = r * rm
        r.normalize()
        c = pymupdf.Point((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2)
        out.extend((c, ch) for ch in str(w[4]) if not ch.isspace())
    return out


def _near(box: pymupdf.Rect) -> pymupdf.Rect:
    """这一行的「邻域」: bbox 四周放宽 LINE_PAD_RATIO 个行高。"""
    pad = max(box.height * LINE_PAD_RATIO, 1.0)
    return pymupdf.Rect(box.x0 - pad, box.y0 - pad, box.x1 + pad, box.y1 + pad)


def _chars_near(box: pymupdf.Rect, chars: list) -> Counter:
    """落在该行邻域内的字符(按字心归属, 免得邻行的字被算进来)。"""
    nb = _near(box)
    c: Counter = Counter()
    for pt, t in chars:
        if nb.contains(pt):
            c[t] += 1
    return c


def _verify(pdf: Path, src: Path, boxes: dict, font: pymupdf.Font,
            opts: Options, warn: list) -> dict:
    """重新打开输出, 量两件事: **逐行**取回率, 以及 search_for 命中框离原 bbox 多远。

    逐行而不是整页字符多重集(2026-10 验收): 整页比对不看位置、不看条数, 重复
    嵌入只会让它更高, 整层横向错位照样 1.0000, 而且页面**原有**的文字(没被判为
    native 的水印/页码层)还能替嵌失败的字顶数。
    这里改成: 每一行的字必须出现在**它自己 bbox 的邻域**里, 并且先把源 PDF
    同一邻域内本来就有的字扣掉, 顶替不了。
    """
    doc = pymupdf.open(pdf)
    sdoc = pymupdf.open(src)
    try:
        total_in = total_hit = 0
        lines_total = lines_ok = 0
        worst = (2.0, None)          # 2.0 = 比任何比例都大, 保证第一页必定被记下来
        low_pages = []
        for pno, items in sorted(boxes.items()):
            words = _page_chars(doc[pno])
            base = _page_chars(sdoc[pno]) if pno < sdoc.page_count else []
            p_in = p_hit = 0
            for box, text, _fs in items:
                want = Counter(c for c in text if not c.isspace())
                n = sum(want.values())
                if not n:
                    continue
                got = _chars_near(box, words)
                if base:                       # 扣掉源 PDF 本来就有的字
                    got = got - _chars_near(box, base)
                hit = sum((want & got).values())
                lines_total += 1
                lines_ok += 1 if hit == n else 0
                p_in += n
                p_hit += hit
            total_in += p_in
            total_hit += p_hit
            ratio = p_hit / p_in if p_in else 1.0
            if ratio < worst[0]:
                worst = (ratio, pno + 1)
            if ratio < opts.min_retrieval:
                low_pages.append({"page": pno + 1, "retrieval": round(ratio, 4)})

        retrieval = (total_hit / total_in) if total_in else None
        line_retrieval = (lines_ok / lines_total) if lines_total else None
        if retrieval is None:
            warn.append("本书未识别出任何文字: 没有一行被嵌进文字层, "
                        "取回率无从谈起(不是 1.0000)。请检查 OCR 结果。")
            worst = (None, None)
        elif retrieval < opts.min_retrieval:
            warn.append(
                f"逐行字符取回率 {retrieval:.4f} 低于阈值 {opts.min_retrieval}; "
                f"最差第{worst[1]}页 {worst[0]:.4f}"
            )
        if line_retrieval is not None and line_retrieval < opts.min_retrieval:
            warn.append(
                f"行级取回率 {line_retrieval:.4f} "
                f"({lines_ok}/{lines_total} 行的字完整出现在自己 bbox 附近)"
            )

        # 定位抽查: 每页取 probe_per_page 条, 全书不超过 probe 条。
        # (旧做法是「全书 12 条」, 400 页的书平均 30 多页才抽到 1 条。)
        picks = _pick_probes(boxes, opts)

        offsets, dys, outside, misses = [], [], 0, []
        for pno, box, text, fs in picks:
            page = doc[pno]
            snip = _snippet(text)
            # 片段只是整行的一截, 要跟它**应该**落在的子矩形比, 跟整行 bbox 比会把
            # "片段在行内的横向位置" 当成误差报出来。按字宽比例切出期望子矩形。
            want = _subrect(box, text, snip, font, fs)
            hits = page.search_for(snip)
            if page.rotation:
                rm = pymupdf.Matrix(page.rotation_matrix)
                hits = [pymupdf.Rect(h) * rm for h in hits]
            if not hits:
                misses.append({"page": pno + 1, "snippet": snip})
                continue
            want_c = _center(want)
            best = min(hits, key=lambda h: abs(_center(h) - want_c))
            got_c = _center(best)
            offsets.append(abs(got_c - want_c))
            dys.append(abs(got_c.y - want_c.y))
            # 命中框中心应落在该行 bbox(上下各放宽半个行高)之内
            tol = pymupdf.Rect(box.x0, box.y0 - box.height / 2,
                               box.x1, box.y1 + box.height / 2)
            if not tol.contains(got_c):
                outside += 1

        probe = {
            "checked": len(picks),
            "found": len(offsets),
            "missed": len(misses),
            "pages_sampled": len({p for p, *_ in picks}),
            "miss_samples": misses[:5],
            "outside_line_box": outside,
            "mean_offset_pt": round(sum(offsets) / len(offsets), 2) if offsets else None,
            "max_offset_pt": round(max(offsets), 2) if offsets else None,
            "max_dy_pt": round(max(dys), 2) if dys else None,
        }
        if outside:
            warn.append(f"定位抽查有 {outside}/{len(offsets)} 条命中框中心落在该行 bbox 之外")
        if misses:
            warn.append(f"定位抽查有 {len(misses)}/{len(picks)} 条 search_for 没命中")
        return {
            "chars_in": total_in,
            "chars_retrieved": total_hit,
            "retrieval": round(retrieval, 4) if retrieval is not None else None,
            "retrieval_worst_page": worst[1],
            "retrieval_worst": round(worst[0], 4) if worst[1] else None,
            "pages_below_threshold": low_pages,
            "min_retrieval": opts.min_retrieval,
            "lines_checked": lines_total,
            "lines_located": lines_ok,
            "line_retrieval": round(line_retrieval, 4)
                              if line_retrieval is not None else None,
            "probe": probe,
        }
    finally:
        doc.close()
        sdoc.close()


def _pick_probes(boxes: dict, opts: Options) -> list:
    """每页取 probe_per_page 条(页内均匀), 全书不超过 opts.probe 条。

    页数多到装不下时**按页**抽样(每隔若干页取一页), 而不是在全书的行池里等距
    取 —— 后者在 400 页的书上会把抽查全挤到少数几页。
    """
    if opts.probe <= 0 or opts.probe_per_page <= 0:
        return []
    per_page = {pno: [(pno, b, t, fs) for b, t, fs in items if _snippet(t)]
                for pno, items in sorted(boxes.items())}
    pages = [p for p, v in per_page.items() if v]
    if not pages:
        return []
    want_pages = max(1, opts.probe // opts.probe_per_page)
    if len(pages) > want_pages:
        step = len(pages) / want_pages
        pages = [pages[min(len(pages) - 1, int(i * step))]
                 for i in range(want_pages)]
    picks = []
    for pno in pages:
        pool = per_page[pno]
        k = min(opts.probe_per_page, len(pool))
        step = max(1, len(pool) // k)
        picks.extend(pool[::step][:k])
        if len(picks) >= opts.probe:
            break
    return picks[:opts.probe]


def _kb(n: int) -> str:
    return f"{n / 1024:.0f} KB" if n < 1024 * 1024 else f"{n / 1048576:.2f} MB"


def _report(s: dict) -> None:
    w = sys.stderr
    print(f"-> {s['out']}", file=w)
    print(
        f"   页: 共{s['pages']} 嵌字{s['pages_embedded']}"
        f" 跳过(已有文字层){s['pages_skipped_native']}"
        f" 跳过(无 OCR){s['pages_skipped_no_json']}"
        f" 跳过(无内容){s['pages_skipped_empty']}"
        f" 旋转页{s['pages_rotated']}",
        file=w,
    )
    print(f"   行: 输入{s['lines_in']} 写入{s['lines_written']} 丢弃{s['lines_dropped']}", file=w)
    #  一行字都没嵌进去时 retrieval 是 None: 必须说「没有可校验的字」,
    #  不能印 1.0000 —— 那会让「整本没识别出东西」看起来像「完美」。
    if s["retrieval"] is None:
        print("   取回率: 无 (本书没有一行被嵌进文字层, 无从校验)", file=w)
    else:
        worst = (f"  最差第{s['retrieval_worst_page']}页 {s['retrieval_worst']}"
                 if s["retrieval_worst_page"] else "")
        print(
            f"   取回率: {s['retrieval']:.4f} "
            f"({s['chars_retrieved']}/{s['chars_in']} 字){worst}"
            + ("" if s['retrieval'] >= s['min_retrieval']
               else f"  ** 低于 {s['min_retrieval']} **"),
            file=w,
        )
        print(
            f"   行级取回: {s['line_retrieval']:.4f} "
            f"({s['lines_located']}/{s['lines_checked']} 行整行落在自己 bbox 邻域内)",
            file=w,
        )
    p = s["probe"]
    if not p["checked"]:
        print("   定位抽查: 未抽查", file=w)
    else:
        print(
            f"   定位抽查: {p['found']}/{p['checked']} 命中"
            f"(覆盖 {p['pages_sampled']} 页)  中心偏差 平均{p['mean_offset_pt']}pt"
            f" 最大{p['max_offset_pt']}pt (纵向最大{p['max_dy_pt']}pt)"
            f"  越界{p['outside_line_box']}条",
            file=w,
        )
    print(
        f"   体积: {_kb(s['size_in'])} -> {_kb(s['size_out'])}"
        f" (×{s['size_ratio']}, 子集化={'是' if s['subset_fonts'] else '否'})",
        file=w,
    )
    for msg in s["warnings"][:20]:
        print(f"   ! {msg}", file=w)
    if len(s["warnings"]) > 20:
        print(f"   ! ...另有 {len(s['warnings']) - 20} 条告警", file=w)


def main(argv: Optional[list] = None) -> int:
    ap = argparse.ArgumentParser(
        description="把 fused.json 的 OCR 结果作为隐形文字层嵌进原 PDF, 产出可搜索 PDF。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("src", help="源 PDF(原始扫描件)")
    ap.add_argument("fused", help="work/<名>.fused.json")
    ap.add_argument("--out", default=None, help="输出路径, 默认 output/<源名>.searchable.pdf")
    ap.add_argument("--force", action="store_true", help="目标已存在时覆盖")
    ap.add_argument("--force-text", action="store_true",
                    help="对 native_text=true 的页也嵌字(默认跳过, 免得搜出双份)")
    ap.add_argument("--min-retrieval", type=float, default=DEFAULT_MIN_RETRIEVAL,
                    help=f"取回率告警阈值, 默认 {DEFAULT_MIN_RETRIEVAL}")
    ap.add_argument("--probe", type=int, default=DEFAULT_PROBE,
                    help=f"search_for 抽查条数上限(全书), 默认 {DEFAULT_PROBE}; 0=不抽查")
    ap.add_argument("--probe-per-page", type=int, default=DEFAULT_PROBE_PER_PAGE,
                    help=f"每页抽查几条, 默认 {DEFAULT_PROBE_PER_PAGE}")
    sub = ap.add_mutually_exclusive_group()
    sub.add_argument("--subset", dest="subset", action="store_true", default=None,
                     help="强制子集化字体")
    sub.add_argument("--no-subset", dest="subset", action="store_false",
                     help="不子集化(源文档本来就有文字层时的默认行为)")
    ap.add_argument("--quiet", action="store_true", help="不打印统计")
    ap.add_argument("--json", action="store_true", help="把 stats 以 JSON 打到 stdout")
    a = ap.parse_args(argv)

    opts = Options(
        force=a.force, force_text=a.force_text, subset=a.subset,
        min_retrieval=a.min_retrieval, probe=a.probe,
        probe_per_page=a.probe_per_page, verbose=not a.quiet,
    )
    try:
        stats = embed(a.src, a.fused, a.out, opts)
    except (FileExistsError, FileNotFoundError, ValueError) as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 2
    if a.json:
        print(json.dumps(stats, ensure_ascii=False, indent=1))
    #  retrieval=None = 一个字都没嵌进去, 这是失败不是满分
    if stats["retrieval"] is None:
        return 1
    return 1 if stats["retrieval"] < stats["min_retrieval"] else 0


if __name__ == "__main__":
    sys.exit(main())
