#!/usr/bin/env python3
"""书籍线 · 批处理驱动: input/*.pdf -> output/<名>.md + output/<名>.searchable.pdf

全自动、纯本地、没有人工校对环节。每份 PDF 依次走:

    渲染 + 双引擎 OCR      book_engines.ocr_pdf   -> work/<名>.{vision,rapidocr}.json
    自动融合(含术语表)      book_fuse.fuse         -> work/<名>.fused.json
    段落化 Markdown        book_md.to_markdown    -> output/<名>.md
    隐形文字层             book_pdf.embed         -> output/<名>.searchable.pdf
    质量报告                                       -> work/<名>.report.md

和剧本线(run.sh / to_markdown.py / crosscheck.py)完全解耦: 本模块只 import
书籍线的 book_*.py, 不碰剧本线的任何文件, 也不写剧本线的任何产物。

覆盖保护(整条线一致, 因为 work/ 和 output/ 下的旧文件可能是别的会话的输入):
  - 两个最终产物都在          -> 跳过这份 PDF(这是「批处理重跑」的正常路径)
  - 任何中间/最终文件已存在    -> 拒绝写, 报错并继续下一份(动工**前**就查, 见
                                precheck_paths: 失败不留半成品)
  - --resume                 -> 已存在且**通过契约校验**的中间产物直接复用,
                                缺什么补什么, 仍然一个字都不覆盖
  - --force                  -> 全部重做并覆盖, 但只覆盖**带本线归属标记**的
                                md / searchable.pdf(见 MD_MARK / PDF_PRODUCER);
                                标记读不到一律当别人的文件, 要 --clobber 才动

术语表(config/glossary.txt)是按剧本整理的纯子串替换, 对别的书会把对的字改错
(实测「大谷翔平」->「大爷翔平」), 而这条线没有人工校对兜底 —— 所以**默认不加载**,
要用得显式 --glossary PATH, 并且每一次替换都会逐条列进质量报告。

用法:
  .venv/bin/python src/run_books.py [--input input] [--outdir output]
        [--dpi 300] [--max-dpi 600] [--pages N|A-B] [--jobs N]
        [--engine both|vision|rapidocr] [--force-ocr]
        [--force] [--clobber] [--resume] [--keep-pages] [--work-dir DIR]
        [--glossary PATH] [--no-page-marks] [--allow-repaired]
退出码: 0 全部成功; 1 有文件失败; 2 用法/输入错误; 3 全部跑完但有降级
        (结构损坏的 PDF、整页 OCR 失败、大面积空页、已有文字层可疑而跳过了
         识别 —— 产物不可全信, 逐份看报告首屏的降级清单)。
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
import time
import traceback
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

_SRC = Path(__file__).resolve().parent
if str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))
ROOT = _SRC.parent

import pymupdf                                               # noqa: E402

import book_md                                              # noqa: E402
import book_pdf                                             # noqa: E402
from book_engines import DEFAULT_DPI, ENGINES, default_jobs, ocr_pdf  # noqa: E402
from book_fuse import FuseRules, fuse, summarize            # noqa: E402
from postcheck import load_glossary                         # noqa: E402

#  书籍线 JSON 必须有的页级字段。剧本线的 run_vision.py / run_rapidocr.py
#  产出的 JSON 只有 page/width/height/image/lines —— 缺 zoom 就没法把像素换回
#  PDF 点, 嵌字会全错。--resume 复用前必须卡这一关, 否则会静默吃掉剧本线的文件。
CONTRACT_PAGE_FIELDS = ("page", "width", "height", "pdf_width", "pdf_height",
                        "zoom", "rotation", "native_text")

#  归属标记。md / searchable.pdf 的内容认不出出处, 以前靠「work/ 里有没有本线
#  留下的痕迹」推断 —— 那是自己给自己发许可证: 一次**失败**的非 force 运行会先
#  写出 work/<名>.fused.json, 用户照提示加 --force 重跑, 推断就变真, 剧本线的
#  output/<名>.md 被静默盖掉(实测不可恢复, 本项目没有 git)。
#  现在只认写在产物自己身上的显式标记, 读不到一律当异己文件, 要 --clobber。
MD_MARK = "<!-- generated-by: book-line -->"
PDF_PRODUCER = "ocr-book-line"


class BookError(Exception):
    """单份 PDF 的可预期失败。打印消息即可, 不需要 traceback。"""


class Cancelled(Exception):
    """调用方(GUI)要求中断本批。只有 run_batch 这条路会抛, CLI 永远碰不到。

    从 should_cancel()/进度回调里抛出, 一路穿过 book_engines.ocr_pdf 的
    try/finally —— 本次渲染出来的页图照常清掉, 不留几百 MB 孤儿文件。
    """


# ============================ 工具 ============================

def log(msg: str = "") -> None:
    print(msg, file=sys.stderr, flush=True)


def human(n: float) -> str:
    return f"{n / 1024:.0f} KB" if n < 1024 * 1024 else f"{n / 1048576:.2f} MB"


def find_pdfs(d: Path) -> list[Path]:
    """目录下所有 *.pdf(不递归)。跳过 .DS_Store 之类的隐藏文件。"""
    if not d.is_dir():
        raise SystemExit(f"输入目录不存在: {d}")
    return sorted((p for p in d.iterdir()
                   if p.is_file() and not p.name.startswith(".")
                   and p.suffix.lower() == ".pdf"),
                  key=lambda p: p.name)


def preflight(pdf: Path, allow_repaired: bool = False) -> tuple[int, bool]:
    """开工前先确认这份 PDF 打得开, 并拿到 (页数, 是否被 MuPDF 自动修复过)。

    不先查: 损坏文件和加密文件会在渲染中途抛库里的异常, 整屏 traceback,
    用户看不出是「这份文件的问题」还是「流水线坏了」。

    is_repaired 必须单独拦: MuPDF 对截断/损坏的 PDF 会自动 repair 后照常打开,
    于是半本书的内容渲染成白页、OCR 出 0 行, 而汇总打「✓」、取回率还写 1.0000
    (取回率是字符多重集包含判定, 没嵌进去的字根本不参与分母)。全自动无人校对
    的流水线里这是最坏的失效形态 —— 错得理直气壮。默认直接不处理。
    """
    try:
        with pymupdf.open(str(pdf)) as doc:
            if doc.needs_pass:
                raise BookError("PDF 带打开口令(加密), 书籍线不处理加密文件 —— "
                                "先用阅读器去掉口令另存一份再放进来。")
            repaired = bool(getattr(doc, "is_repaired", False))
            n = doc.page_count
    except BookError:
        raise
    except Exception as e:                                   # noqa: BLE001
        raise BookError(f"打不开(文件损坏或不是 PDF): {type(e).__name__}: {e}") from None
    if n <= 0:
        raise BookError("这份 PDF 一页都没有")
    if repaired and not allow_repaired:
        raise BookError(
            "PDF 结构损坏 —— MuPDF 自动修复之后才打得开(is_repaired), "
            "页面可能缺失、错乱或渲染成白页, 识别结果不可信, 不处理。\n"
            "    先用阅读器/qpdf 另存一份完好的再放进来; "
            "确实要尽力处理就加 --allow-repaired(结果按**降级**计, 退出码 3)。")
    return n, repaired


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:                                   # noqa: BLE001
        raise BookError(f"{path} 读不动: {e}") from None


def check_engine_doc(doc: dict, path: Path, engine: str, stem: str) -> dict:
    """复用前的契约校验。不合契约就报错, 绝不将就着用。"""
    if doc.get("engine") != engine:
        raise BookError(f"{path} 的 engine 是 {doc.get('engine')!r}, 期望 {engine!r}")
    pages = doc.get("pages")
    if not isinstance(pages, list) or not pages:
        raise BookError(f"{path} 没有 pages")
    missing = [f for f in CONTRACT_PAGE_FIELDS if f not in pages[0]]
    if missing:
        raise BookError(
            f"{path} 不是书籍线的 JSON(页里缺 {', '.join(missing)}) —— "
            f"多半是剧本线 run_{engine}.py 的产物。换 --work-dir, 或加 --force 重做。")
    src_stem = Path(str(doc.get("source", ""))).stem
    if src_stem and src_stem != stem:
        raise BookError(f"{path} 的 source 是 {src_stem!r}, 不是 {stem!r}")
    return doc


def check_fused_doc(doc: dict, path: Path) -> dict:
    pages = doc.get("pages")
    if not isinstance(pages, list) or not pages or "stats" not in doc:
        raise BookError(f"{path} 不像 fused.json(缺 pages 或 stats)")
    missing = [f for f in CONTRACT_PAGE_FIELDS if f not in pages[0]]
    if missing:
        raise BookError(f"{path} 缺页级字段 {', '.join(missing)}, 不能复用")
    return doc


def guard_write(path: Path, force: bool) -> None:
    if path.exists() and not force:
        raise BookError(f"{path} 已存在, 拒绝覆盖。加 --resume 复用, 或 --force 重做。")


def write_text(path: Path, text: str, force: bool) -> None:
    """先写 .part 再 replace: 几百页跑十几分钟, 中途 Ctrl-C 不能留半截 md。

    (book_pdf.embed 内部已经是这个写法, 这里给 md / report 补齐。)
    """
    guard_write(path, force)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".part")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


# ============================ 配置 ============================

@dataclass
class Config:
    input: Path
    outdir: Path
    workdir: Path
    dpi: float = DEFAULT_DPI
    jobs: int | None = None
    engine: str = "both"
    force: bool = False
    resume: bool = False
    keep_pages: bool = False
    page_marks: bool = True
    min_retrieval: float = book_pdf.DEFAULT_MIN_RETRIEVAL
    native_dpi: bool = True              # 内嵌图分辨率比 --dpi 高时自动提升
    max_dpi: float | None = None         # None = 用 book_render 的 MAX_DPI
    pages: str | None = None             # "N" 或 "A-B", 先跑前几页试水
    force_ocr: bool = False              # 无视原生文字层, 一律当扫描页重认
    allow_repaired: bool = False         # 结构损坏的 PDF 也尽力处理(降级)
    subset: bool | None = None           # None = 交给 book_pdf 自己判断
    clobber: bool = False                # --force 时连「不是本线产出」的同名文件也覆盖
    glossary_path: Path | None = None
    glossary: list = field(default_factory=list)

    @property
    def render_kw(self) -> dict:
        """透传给 ocr_pdf -> render_pdf -> iter_pages 的可选渲染参数。

        只放用户显式给了值的键: iter_pages 的默认值(MAX_DPI 等)是单一事实来源,
        这里不复制一份。
        """
        kw: dict = {"use_native_dpi": self.native_dpi, "force_ocr": self.force_ocr}
        if self.max_dpi is not None:
            kw["max_dpi"] = self.max_dpi
        if self.pages:
            kw["pages"] = self.pages
        return kw

    @property
    def engines(self) -> list[str]:
        return list(ENGINES) if self.engine == "both" else [self.engine]


# ============================ 单引擎补空壳 ============================

def _empty_doc(like: dict, engine: str) -> dict:
    """--engine vision|rapidocr 时, 给 fuse() 造一份同几何的空文档。

    这样单引擎也走同一条融合路径, 行全部记成 only_<engine>, 契约字段齐全,
    下游(md / 嵌字)完全不用区分单双引擎。
    """
    return {
        "source": like.get("source"),
        "engine": engine,
        "dpi": like.get("dpi"),
        "pages": [{k: p[k] for k in CONTRACT_PAGE_FIELDS if k in p} | {"lines": []}
                  for p in like.get("pages", [])],
    }


# ============================ 各阶段 ============================

def stage_ocr(pdf: Path, cfg: Config, stem: str, prog
              ) -> tuple[dict[str, dict], list[int], list[int], float]:
    """返回 {engine: doc}、整页识别失败的页号、原生文字层可疑的页号、耗时。

    已有且合契约的 JSON 在 --resume 下直接复用。
    """
    t0 = time.time()
    paths = {e: cfg.workdir / f"{stem}.{e}.json" for e in cfg.engines}
    docs: dict[str, dict] = {}
    todo: list[str] = []
    failed: list[int] = []
    single: list[int] = []
    suspect: list[int] = []

    for e, p in paths.items():
        if p.exists() and not cfg.force:
            if not cfg.resume:
                raise BookError(
                    f"{p} 已存在, 拒绝覆盖。加 --resume 复用, 或 --force 重做。")
            docs[e] = check_engine_doc(load_json(p), p, e, stem)
            log(f"  · 复用 {p.name}")
        else:
            todo.append(e)

    if todo:
        want = "both" if len(todo) == 2 else todo[0]
        #  页图(work/<名>/pages/pg-*.png)是本线自己的临时文件, 重画覆盖没有风险,
        #  而 --resume 要收拾的正是「上次被 Ctrl-C/kill 打断、页图还留着」的现场
        #  —— 不放行这一项, --resume 在它唯一存在的场景里 100% 报「拒绝覆盖」。
        #  JSON / 最终产物的覆盖保护不受影响: todo 里的 JSON 本来就不存在,
        #  md / searchable.pdf 由 stage_md / stage_pdf 各自把关。
        res = ocr_pdf(pdf, dpi=cfg.dpi, engine=want, jobs=cfg.jobs,
                      keep_pages=cfg.keep_pages, work_dir=cfg.workdir,
                      force=cfg.force or cfg.resume, verbose=True, progress=prog,
                      **cfg.render_kw)
        for e in todo:
            docs[e] = load_json(paths[e])
        #  res.failed 是两个引擎各自的失败页**并集**(各自 extend), 所以同一页
        #  两边都崩时会出现两次。这两种情况后果完全不同, 不能混为一谈:
        #    两边都崩 -> 这页在 md 和文字层里是真的缺内容
        #    只崩一边 -> 内容还在(另一引擎读到了), 只是这页没有交叉验证
        #  混着报会让用户按「这页没了」去处理一页其实只少了一份对照读法的页。
        cnt = Counter(res.failed or ())
        n_eng = max(1, len(want))
        failed = sorted(p for p, c in cnt.items() if c >= n_eng)
        single = sorted(p for p, c in cnt.items() if c < n_eng)
        if failed:
            log(f"  ⚠ {len(failed)} 页两个引擎都失败(内容缺失): {failed[:20]}")
        if single:
            log(f"  ⚠ {len(single)} 页只有一个引擎读到(内容在, 但没有交叉验证): "
                f"{single[:20]}")
        #  已有文字层被判可疑(乱码层/「囗囗囗」占位层/行数对不上图)。这些页
        #  **跳过了双引擎识别**, md 和文字层全部来自那层旧文字 —— 实测会产出
        #  整本垃圾, 而取回率照样 1.0000。必须让它浮到报告和退出码上。
        suspect = sorted(set(res.native_suspect or ()))
        if suspect:
            log(f"  ⚠ {len(suspect)} 页的已有文字层可疑: {suspect[:20]} "
                f"—— 这些页跳过了 OCR, 产物直接来自那层旧文字。"
                f"md 看着是乱码就加 --force-ocr 重跑。")
    return docs, failed, single, suspect, time.time() - t0


def stage_fuse(docs: dict[str, dict], cfg: Config, stem: str
               ) -> tuple[dict, list[dict], Path, float]:
    t0 = time.time()
    out = cfg.workdir / f"{stem}.fused.json"
    decisions: list[dict] = []

    if out.exists() and not cfg.force and cfg.resume:
        fused = check_fused_doc(load_json(out), out)
        log(f"  · 复用 {out.name}")
        return fused, decisions, out, time.time() - t0

    guard_write(out, cfg.force)
    rules = FuseRules(glossary=cfg.glossary)
    vdoc = docs.get("vision") or _empty_doc(docs["rapidocr"], "vision")
    rdoc = docs.get("rapidocr") or _empty_doc(docs["vision"], "rapidocr")
    try:
        fused = fuse(vdoc, rdoc, rules, decisions=decisions)
    except ValueError as e:
        raise BookError(f"融合失败: {e}") from None
    #  fuse() 固定写两个引擎名; 单引擎时如实改掉(契约固定的是字段名, 不是值)
    fused["engines"] = cfg.engines
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(fused, ensure_ascii=False, indent=1), encoding="utf-8")
    return fused, decisions, out, time.time() - t0


def stage_md(fused: dict, cfg: Config, stem: str) -> tuple[Path, dict, list, float]:
    t0 = time.time()
    out = cfg.outdir / f"{stem}.md"
    opts = book_md.Options(page_marks=cfg.page_marks)
    if out.exists() and not cfg.force and cfg.resume:
        log(f"  · 保留已有 {out.name}")
        book_md.to_markdown(fused, opts)          # 只为拿统计, 不写文件
        return out, opts.stats, opts.report, time.time() - t0
    md = book_md.to_markdown(fused, opts)
    #  归属标记写在最前面(驱动侧加, book_md 的输出一个字不动)。--force 靠它
    #  认「这份 md 是不是本线写的」, 见 foreign_targets。
    write_text(out, f"{MD_MARK}\n\n{md.lstrip(chr(10))}", cfg.force)
    return out, opts.stats, opts.report, time.time() - t0


def stage_pdf(pdf: Path, fused: dict, cfg: Config, stem: str
              ) -> tuple[Path, dict | None, float]:
    t0 = time.time()
    out = cfg.outdir / f"{stem}.searchable.pdf"
    if out.exists() and not cfg.force and cfg.resume:
        log(f"  · 保留已有 {out.name}")
        return out, None, time.time() - t0
    guard_write(out, cfg.force)
    opts = book_pdf.Options(force=cfg.force, min_retrieval=cfg.min_retrieval,
                            subset=cfg.subset, verbose=False)
    try:
        stats = book_pdf.embed(pdf, fused, out, opts)
    except (FileExistsError, FileNotFoundError, ValueError) as e:
        raise BookError(f"嵌字失败: {e}") from None
    mark_pdf_producer(out)
    return out, stats, time.time() - t0


# ============================ 质量报告 ============================

def build_report(pdf: Path, cfg: Config, rep: dict, mdst: dict, mdrep: list,
                 pstats: dict | None, paths: dict[str, Path],
                 timing: dict[str, float], decisions: list[dict],
                 empty_pages: list[int], failed_pages: list[int] | None = None,
                 degraded: list[str] | None = None,
                 src_pages: int | None = None,
                 native_suspect: list[int] | None = None,
                 single_engine_pages: list[int] | None = None) -> str:
    """work/<名>.report.md —— 没有人工校对环节时, 用户唯一的质量抓手。"""
    L: list[str] = []
    A = L.append
    failed_pages = failed_pages or []
    single_engine_pages = single_engine_pages or []
    degraded = degraded or []
    native_suspect = native_suspect or []
    total = sum(timing.values())
    npages = max(1, rep["pages"])
    _n = iter(range(1, 99))

    def H(title: str) -> None:                 # 小节号跟着实际有没有这节走
        A(f"## {next(_n)}　{title}")
        A("")

    A(f"# OCR 质量报告 · {pdf.stem}")
    A("")
    if degraded:
        #  首屏就得说清楚: 这份产物不能当成跑成功了
        A("> ## ⚠ 本次运行**已降级**, 产物不可全信")
        A(">")
        for d in degraded:
            A(f"> - {d}")
        A(">")
        A("> 批处理退出码为 3。下面的取回率/分歧率都只统计**真的识别到了的内容**,")
        A("> 丢掉的页不进分母 —— 数字好看不代表这一本是完整的。")
        A("")
    A(f"- 源文件: `{pdf}`  ({human(pdf.stat().st_size)})")
    A(f"- Markdown: `{paths['md']}`")
    A(f"- 可搜索 PDF: `{paths['pdf']}`")
    A(f"- 融合数据: `{paths['fused']}`")
    A(f"- 生成时间: {datetime.now():%Y-%m-%d %H:%M:%S}   "
      f"引擎: {', '.join(cfg.engines)}   基准 dpi: {cfg.dpi:g}")
    A(f"- 耗时: **{total:.1f}s** ({total / npages:.2f}s/页) = "
      + " + ".join(f"{k} {v:.2f}s" for k, v in timing.items()))
    A("")

    # ---- 1 识别 ----
    st = rep["stats"]
    H("识别与融合")
    A("| 项 | 值 |")
    A("|---|---|")
    A(f"| 页数 | {rep['pages']}"
      + (f" / 源 PDF {src_pages}" if src_pages and src_pages != rep["pages"] else "")
      + " |")
    A(f"| 文本行 | {rep['lines']} |")
    A(f"| 双引擎都读到(配对行) | {st['both']} |")
    A(f"| 仅 Vision 读到 | {st['only_vision']} |")
    A(f"| 仅 RapidOCR 读到 | {st['only_rapidocr']} |")
    A(f"| 两引擎分歧(已自动裁决) | {st['divergent']}　"
      f"占配对行 **{rep['divergent_rate'] * 100:.1f}%** |")
    A(f"| 单源行占比 | **{rep['single_source_rate'] * 100:.1f}%** |")
    A(f"| 低可信行 | {rep['low_conf_count']} |")
    A(f"| 术语表命中 | {st['glossary_hits']}"
      + ("(未启用)" if not cfg.glossary else f" <- {cfg.glossary_path}") + " |")
    A(f"| 丢弃的空检测框 | {st['dropped_empty']} |")
    if "dropped_contained" in st:              # book_fuse 的包含去重(有才显示)
        A(f"| 去重(被配对行包含的单源碎片) | {st['dropped_contained']} |")
    A(f"| OCR 失败页(两个引擎都崩, 内容缺失) | {failed_pages or '无'} |")
    A(f"| 只有单引擎读到的页(内容在, 无交叉验证) | {single_engine_pages or '无'} |")
    A(f"| 已有文字层可疑的页 | {native_suspect or '无'} |")
    A(f"| 一行字都没有的页 | {empty_pages or '无'} |")
    A("")
    if failed_pages:
        A(f"> ⚠ 第 {', '.join(map(str, failed_pages))} 页识别时引擎崩了, "
          f"已记空行继续 —— 这些页在 Markdown 和文字层里是**缺的**, "
          f"不是「这页没字」。单独重跑这几页, 或换 --engine 再试一次。")
        A("")
    #  已经在上一条里说清楚是「引擎崩了」的页, 不要再用「可能是插图页」糊过去
    empty_only = [p for p in empty_pages if p not in set(failed_pages)]
    if empty_only:
        A(f"> 第 {', '.join(map(str, empty_only))} 页没有识别出任何文字 —— "
          f"可能是插图页/空白页, 也可能是整页识别失败。"
          f"Markdown 里这些页只留一个 `<!-- page N -->` 标记, "
          f"翻一下原件确认是前者。")
        A("")
    if native_suspect:
        A(f"> ⚠ 第 {', '.join(map(str, native_suspect))} 页**本来就带文字层**, "
          f"按「原生文字页」跳过了双引擎识别 —— 但那层文字质量可疑(乱码/占位符/"
          f"行数和图上的字对不上)。Markdown 和隐形文字层这几页全部来自那层旧文字, "
          f"取回率再高也只说明旧文字被原样搬了过来。"
          f"翻一下 md: 是乱码就加 `--force-ocr` 重跑, 当扫描页重新识别。")
        A("")
    A("> 单源行 = 只有一个引擎读出来、没有第二份读法可对照的行, "
      "是项目实测里残留错误最集中的地方。分歧行已由打分规则自动裁出胜负, "
      "败者保留在 `fused.json` 的 `alt` 字段里。")
    A("")

    # ---- 2 该看哪几页 ----
    H("优先复核的页")
    sus: dict[int, list[str]] = {}
    for p in failed_pages:                     # 最该先看的: 两个引擎都崩了的页
        sus.setdefault(int(p), []).append("**OCR 失败(内容缺失)**")
    for p in single_engine_pages:              # 内容在, 只是没有第二票
        sus.setdefault(int(p), []).append("只有单引擎读到(无交叉验证)")
    for p in native_suspect:
        sus.setdefault(int(p), []).append("已有文字层可疑(跳过了 OCR)")
    for p in empty_pages:
        sus.setdefault(int(p), []).append("一行字都没有")
    for p, n in rep["divergent_by_page"].items():
        sus.setdefault(int(p), []).append(f"分歧 {n} 行")
    for p in rep["low_conf_pages"]:
        sus.setdefault(int(p), []).append("有低可信行")
    for d in (pstats or {}).get("pages_below_threshold", []):
        _r = d.get("retrieval")
        sus.setdefault(int(d["page"]), []).append(
            f"嵌字取回 {_r:.3f}" if _r is not None else "嵌字取回偏低")
    if sus:
        A("| 页 | 原因 |")
        A("|---|---|")
        for p in sorted(sus)[:30]:
            A(f"| {p} | {'、'.join(sus[p])} |")
        if len(sus) > 30:
            A(f"| … | 另有 {len(sus) - 30} 页 |")
    else:
        A("无 —— 没有分歧页、低可信行或取回率偏低的页。")
    A("")

    if rep["low_conf_lines"]:
        A("### 低可信行(最多 12 条)")
        A("")
        A("| 页 | 来源 | conf | 文本 |")
        A("|---|---|---|---|")
        for d in rep["low_conf_lines"]:
            t = d["text"].replace("|", "\\|")[:40]
            A(f"| {d['page']} | {d['src']} | {d['conf']} | {t} |")
        A("")

    arb = [d for d in decisions if d.get("kind", "arbitrate") != "glossary"]
    if arb:
        A("### 自动裁决抽样(最多 8 条)")
        A("")
        A("| 页 | 采用 | vision | rapidocr | 理由 |")
        A("|---|---|---|---|---|")
        for d in arb[:8]:
            v = d["vision"].replace("|", "\\|")[:24]
            r = d["rapidocr"].replace("|", "\\|")[:24]
            A(f"| {d['page']} | {d['winner']} | {v} | {r} | {d['reason']} |")
        A("")

    # ---- 术语表明细(只在启用了术语表时出现) ----
    if cfg.glossary:
        glo = [d for d in decisions if d.get("kind") == "glossary"]
        H("术语表改写明细")
        A(f"术语表 **{len(cfg.glossary)} 条** <- `{cfg.glossary_path}`　"
          f"命中 **{st['glossary_hits']}** 处。")
        A("")
        A("> 术语表是**无词边界、无上下文**的纯子串替换, 书籍线又没有人工校对"
          "兜底 —— 改错了的字在 Markdown 和隐形文字层里同时被改, 原来的读法"
          "不会留在任何地方。所以每一次替换都在这里逐条列出, 逐条核对原图。")
        A("")
        if glo:
            A("| 页 | 规则 | 改前(整行) | 改后(整行) |")
            A("|---|---|---|---|")

            def _c(s: str) -> str:
                return str(s).replace("|", "\\|").replace("\n", " ")[:60]

            for d in glo:
                A(f"| {d.get('page', '?')} | {_c(d.get('rule', ''))} "
                  f"| {_c(d.get('before', ''))} | {_c(d.get('after', ''))} |")
            A("")
        elif st["glossary_hits"]:
            A(f"> ⚠ 命中 {st['glossary_hits']} 处, 但融合阶段没有回传逐条明细 "
              f"(book_fuse 的 decisions 里没有 kind=glossary 的记录) —— "
              f"改了哪几个字查不出来, 建议先 **不加 --glossary** 重跑一遍对比。")
            A("")
        else:
            A("本次没有命中任何规则。")
            A("")

    # ---- Markdown ----
    H("Markdown 版面")
    A("| 项 | 值 |")
    A("|---|---|")
    A(f"| 原始行 → 合行后 → 正文行 | {mdst['lines_in']} → {mdst['rows']} "
      f"→ {mdst['kept_rows']} |")
    A(f"| 段落 / 标题 | {mdst['paragraphs']} / {mdst['headings']} |")
    A(f"| 正文字数 | {mdst['chars']} |")
    det = mdst.get("dropped_detail") or {}
    A(f"| 丢弃 | {mdst['dropped']} 行: "
      f"{'、'.join(f'{k} {v}' for k, v in sorted(det.items())) or '无'} |")
    A("")
    if mdst.get("vertical_pages"):
        A(f"> ⚠ 竖排页 {mdst['vertical_pages']} —— 本版不支持竖排版面, "
          f"已按横排原样输出, md 里留了 WARNING 注释。")
        A("")
    for line in mdrep[:10]:
        A(f"- 页眉判定: {line}")
    if mdrep:
        A("")
    A("> 丢弃的是页码、书眉、页缘碎块这类非正文内容; "
      "逐行原文始终保留在 `fused.json` 和可搜索 PDF 的文字层里, 没有丢字。")
    A("")

    # ---- 嵌字 ----
    H("可搜索 PDF(隐形文字层)")
    if pstats is None:
        A("本次复用了已有文件, 未重新嵌字。")
    else:
        pr = pstats.get("probe") or {}
        ret = pstats.get("retrieval")
        A("| 项 | 值 |")
        A("|---|---|")
        #  retrieval=None = 这本书一个字都没往里嵌(整本原生文字页 / 整本空白)。
        #  这种时候印 1.0000 是在替空结果背书, 所以显式写「没有嵌字」。
        A("| 文字取回率 | "
          + (f"**{ret:.4f}** ({pstats['chars_retrieved']}/{pstats['chars_in']} 字)"
             if ret is not None else
             "**不适用** —— 本次没有往这份 PDF 里嵌任何文字"
             "(整本都是原生文字页, 或整本没识别出字)")
          + " |")
        if pstats.get("retrieval_worst_page"):
            A(f"| 最差页 | 第 {pstats['retrieval_worst_page']} 页 "
              f"{pstats['retrieval_worst']:.4f} |")
        A(f"| 嵌字页 / 总页 | {pstats['pages_embedded']} / {pstats['pages']} |")
        skip = (f"原生文字层 {pstats['pages_skipped_native']}、"
                f"无数据 {pstats['pages_skipped_no_json']}、"
                f"无文本 {pstats['pages_skipped_empty']}")
        A(f"| 跳过 | {skip} |")
        A(f"| 行 写入/丢弃 | {pstats['lines_written']} / {pstats['lines_dropped']} |")
        A(f"| 定位抽查 | 命中 {pr.get('found', 0)}/{pr.get('checked', 0)}, "
          f"平均偏差 {pr.get('mean_offset_pt')} pt, "
          f"最大 {pr.get('max_offset_pt')} pt |")
        A(f"| 体积 | {human(pstats['size_in'])} → {human(pstats['size_out'])} "
          f"(×{pstats['size_ratio']}) |")
        A(f"| 字体子集化 | {'是' if pstats['subset_fonts'] else '否'} |")
        A("")
        if ret is not None and ret < pstats["min_retrieval"]:
            A(f"> ⚠ 取回率低于阈值 {pstats['min_retrieval']} —— "
              f"文字层可能有部分内容搜不到。")
            A("")
        for w in pstats.get("warnings", [])[:20]:
            A(f"- ⚠ {w}")
        if pstats.get("warnings"):
            A("")
    A("> 原页图一字未改, 文字层以 render_mode=3(不可见)叠在原位, "
      "可搜索、可复制、可选中。")
    A("")

    H("这份报告怎么用")
    if degraded:
        A("0. **先解决上面的降级项** —— 在那之前别把这份产物当成稿。")
    A("1. 先看「优先复核的页」, 在可搜索 PDF 里翻到对应页, 选中文字对照原图。")
    A("2. 两引擎一起错的字交叉验证抓不到。发现系统性误读可以整理一张术语表, "
      "用 `--glossary PATH` 显式启用(默认不启用: 纯子串替换对别的书会把对的字"
      "改错, 项目里 `config/glossary.txt` 是**剧本专用**的, 别直接拿来套书)。")
    A("3. 识别质量的上限由扫描分辨率决定。取回率正常但错字多, "
      "先提高扫描 dpi, 比任何后处理都有效。")
    A("4. 几百页的大书先 `--pages 1-10` 跑十来页看质量和速度, 再决定跑整本。")
    return "\n".join(L) + "\n"


def _is_book_json(path: Path) -> bool:
    """这份 JSON 是不是书籍线自己产出的? 靠契约页级字段认。

    剧本线 run_vision.py / run_rapidocr.py 的同名 JSON 只有
    page/width/height/image/lines, 没有 zoom/pdf_width/rotation —— 认得出来。
    """
    try:
        pages = json.loads(path.read_text(encoding="utf-8"))["pages"]
        return bool(pages) and all(f in pages[0] for f in CONTRACT_PAGE_FIELDS)
    except Exception:                                        # noqa: BLE001
        return False


def md_is_mine(path: Path) -> bool:
    """这份 md 开头有没有本线的归属标记。读不到 = 不是我的。"""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            head = f.read(len(MD_MARK) + 8)
    except OSError:
        return False
    return head.lstrip("﻿ \t\r\n").startswith(MD_MARK)


def pdf_is_mine(path: Path) -> bool:
    """这份 PDF 的 producer 是不是本线盖的章。打不开/读不到 = 不是我的。"""
    try:
        with pymupdf.open(str(path)) as doc:
            return (doc.metadata or {}).get("producer") == PDF_PRODUCER
    except Exception:                                        # noqa: BLE001
        return False


def mark_pdf_producer(path: Path) -> None:
    """给刚嵌好字的 searchable.pdf 盖归属章(驱动侧写, 不碰 book_pdf.py)。

    增量保存: 只在文件尾部追加一小段, 页面内容和刚校验过的文字层一个字节不动。
    盖章失败不算嵌字失败 —— 后果只是下次 --force 把它当别人的文件(偏安全的那头)。
    """
    try:
        with pymupdf.open(str(path)) as doc:
            meta = {k: v for k, v in (doc.metadata or {}).items()
                    if k not in ("format", "encryption") and v is not None}
            meta["producer"] = PDF_PRODUCER
            doc.set_metadata(meta)
            doc.save(str(path), incremental=True,
                     encryption=pymupdf.PDF_ENCRYPT_KEEP)
    except Exception as e:                                   # noqa: BLE001
        log(f"  ⚠ 归属标记没能写进 {path.name}: {type(e).__name__}: {e}"
            f" —— 下次 --force 会把它当异己文件, 需要 --clobber。")


def foreign_targets(cfg: Config, stem: str) -> list[Path]:
    """--force 会覆盖的目标里, 哪些**不是**书籍线自己产出的。

    为什么要查: `./books.sh --force` 碰上一份和剧本线同名的 PDF, 会直接盖掉
    output/<名>.md(剧本线的成稿)和 work/<名>.vision.json。这个项目不是 git 仓库,
    覆盖了没有回滚。宁可停下来让用户改名, 也不赌。

    归属只认**写在产物自己身上**的显式标记(JSON 看契约字段, md 看 MD_MARK,
    PDF 看 producer), 不靠「work/ 里有没有本线的中间文件」推断 —— 那些中间文件
    可能正是上一次失败的运行刚写下的, 拿它当凭据等于自己给自己发许可证。
    读不到标记就当别人的文件: 误报只是多打一次 --clobber, 漏报是成稿没了。
    """
    bad: list[Path] = []
    for e in cfg.engines:                      # JSON 能精确认: 看契约字段
        p = cfg.workdir / f"{stem}.{e}.json"
        if p.exists() and not _is_book_json(p):
            bad.append(p)
    fused = cfg.workdir / f"{stem}.fused.json"
    if fused.exists() and not _is_book_json(fused):
        bad.append(fused)
    md = cfg.outdir / f"{stem}.md"
    if md.exists() and not md_is_mine(md):
        bad.append(md)
    sp = cfg.outdir / f"{stem}.searchable.pdf"
    if sp.exists() and not pdf_is_mine(sp):
        bad.append(sp)
    return bad


def precheck_paths(cfg: Config, stem: str) -> None:
    """动工**前**把这份 PDF 会写的所有路径一起过一遍守卫。

    不先查: 各阶段边算边写, md 这一步才撞上「已存在」时, work/ 下已经留了
    <名>.{vision,rapidocr,fused}.json 三份 —— 「失败的不留半成品」就不成立了,
    而且这些半成品还会改变下一次 --force 的判断。
    """
    if cfg.force and not cfg.clobber:
        bad = foreign_targets(cfg, stem)
        if bad:
            raise BookError(
                "--force 会覆盖这些**不像是书籍线产出**的同名文件:\n      "
                + "\n      ".join(str(b) for b in bad)
                + "\n    (没有本线的归属标记 —— 多半是剧本线 run.sh 的产物,"
                  " 本项目没有 git, 覆盖不可恢复。)"
                  "\n    改 PDF 文件名、或换 --outdir/--work-dir;"
                  " 确认就是要覆盖再加 --clobber。")
    if cfg.force or cfg.resume:
        return                                 # 覆盖/复用本来就是这两个开关的语义
    targets = [cfg.workdir / f"{stem}.{e}.json" for e in cfg.engines]
    targets += [cfg.workdir / f"{stem}.fused.json",
                cfg.outdir / f"{stem}.md",
                cfg.outdir / f"{stem}.searchable.pdf"]
    clash = [p for p in targets if p.exists()]
    if clash:
        raise BookError(
            "这些要写的文件已经存在, 拒绝覆盖(还没动工, 没留下任何半成品):\n      "
            + "\n      ".join(str(p) for p in clash)
            + "\n    加 --resume 复用已有的中间产物, 或 --force 重做。")


# ============================ 单份处理 ============================

def process_one(pdf: Path, cfg: Config, tag: str, on_event=None,
                should_cancel=None) -> dict:
    """on_event / should_cancel 都是给 GUI 的可选钩子, CLI 不传 -> 行为不变。

    on_event(dict): 阶段与逐页进度, 事件契约见 run_batch 的 docstring。
    should_cancel() -> bool: 在阶段边界和每页进度回调里问一次, True 则抛 Cancelled。
    """
    stem = pdf.stem
    md_out = cfg.outdir / f"{stem}.md"
    pdf_out = cfg.outdir / f"{stem}.searchable.pdf"
    rec: dict = {"pdf": pdf, "stem": stem}

    def emit(kind: str, **kw) -> None:
        if on_event is not None:
            on_event({"type": kind, "stem": stem, "pdf": str(pdf), **kw})

    def ck() -> None:
        if should_cancel is not None and should_cancel():
            raise Cancelled()

    log("")
    log(f"══════ {tag}  {pdf.name}  ({human(pdf.stat().st_size)}) ══════")
    if md_out.exists() and pdf_out.exists() and not cfg.force:
        log(f"  跳过: 两个产物都已存在 ({md_out.name}, {pdf_out.name})。"
            f"要重做加 --force。")
        rec["status"] = "skipped"
        return rec

    precheck_paths(cfg, stem)

    degraded: list[str] = []
    npages, repaired = preflight(pdf, cfg.allow_repaired)
    log(f"  共 {npages} 页")
    if repaired:
        degraded.append("PDF 结构损坏(MuPDF 自动修复后才打开), 页面可能缺失/错乱")
        log("  ⚠ PDF 结构损坏, --allow-repaired 下尽力处理: "
            "页面可能缺失或渲染成白页, 结果按降级计")
    t_all = time.time()
    timing: dict[str, float] = {}

    emit("pages", pages=npages, repaired=repaired)

    def prog(done: int, total: int, engine: str) -> None:
        #  日志按 5% 节流(几百页刷屏), 但事件逐页都发: GUI 的进度条要真实推进。
        if total and (done == total or done % max(1, total // 20) == 0):
            log(f"    {engine} {done}/{total} 页 ({done * 100 // total}%)")
        emit("progress", engine=engine, done=done, total=total)
        ck()

    ck()
    emit("stage", stage="ocr", step=1, steps=4, label="渲染 + OCR")
    log("  [1/4] 渲染 + OCR")
    (docs, failed_pages, single_engine_pages,
     suspect_pages, timing["OCR"]) = stage_ocr(pdf, cfg, stem, prog)
    if failed_pages:
        degraded.append(f"{len(failed_pages)} 页两个引擎都失败(内容缺失)")
    if suspect_pages:
        degraded.append(f"{len(suspect_pages)} 页的已有文字层可疑, "
                        f"这些页跳过了 OCR(产物来自旧文字层; 要重认加 --force-ocr)")

    ck()
    emit("stage", stage="fuse", step=2, steps=4, label="双引擎融合")
    log("  [2/4] 双引擎融合")
    fused, decisions, fused_path, timing["融合"] = stage_fuse(docs, cfg, stem)
    rep = summarize(fused, decisions)
    log(f"    {rep['pages']} 页 {rep['lines']} 行   "
        f"分歧 {rep['stats']['divergent']} ({rep['divergent_rate'] * 100:.1f}%)   "
        f"单源 {rep['single_source_rate'] * 100:.1f}%   "
        f"低可信 {rep['low_conf_count']}   术语表 {rep['stats']['glossary_hits']}")

    ck()
    emit("stage", stage="markdown", step=3, steps=4, label="段落化 Markdown")
    log("  [3/4] 段落化 Markdown")
    md_path, mdst, mdrep, timing["Markdown"] = stage_md(fused, cfg, stem)
    log(f"    {mdst['paragraphs']} 段 {mdst['headings']} 标题 {mdst['chars']} 字   "
        f"丢弃 {mdst['dropped']} 行 -> {md_path}")

    ck()
    emit("stage", stage="embed", step=4, steps=4, label="可搜索 PDF(隐形文字层)")
    log("  [4/4] 可搜索 PDF")
    sp_path, pstats, timing["嵌字"] = stage_pdf(pdf, fused, cfg, stem)
    if pstats:
        #  retrieval 可以是 None(整本原生文字页 -> 一个字都没嵌)。直接 :.4f 会
        #  TypeError, 整份 PDF 被当成「失败」—— 实测 --force-ocr 那条线就踩过。
        r = pstats.get("retrieval")
        log(f"    取回 "
            + (f"{r:.4f} ({pstats['chars_retrieved']}/{pstats['chars_in']} 字)"
               if r is not None else "不适用(本次没嵌任何文字)")
            + f"   {human(pstats['size_in'])} -> {human(pstats['size_out'])}"
              f" -> {sp_path}")

    report_path = cfg.workdir / f"{stem}.report.md"
    empty_pages = [p["page"] for p in fused["pages"] if not p["lines"]]
    if empty_pages:
        log(f"    注意: 第 {empty_pages} 页没有识别出任何文字(插图页/空白页?)")

    #  「一行字都没有的页」占比告警: 插图页零星几张正常, 成片出现多半是渲染/
    #  识别出了事(截断的 PDF 就长这样 —— 坏页全白, md 只剩一半, 取回率照样 1.0)。
    done = max(1, rep["pages"])
    if len(empty_pages) >= 2 and len(empty_pages) >= done / 3:
        degraded.append(
            f"{len(empty_pages)}/{done} 页一行字都没有 —— 比值过高, 不像是插图页")
        log(f"  ⚠ {len(empty_pages)}/{done} 页没有任何文字, 比值过高, 按降级计")
    #  渲染到的页数对不上源 PDF 的页数(没用 --pages 限制时): 多半是坏页被跳过
    if cfg.pages is None and rep["pages"] < npages:
        degraded.append(f"只处理到 {rep['pages']}/{npages} 页")
        log(f"  ⚠ 源 PDF {npages} 页, 只处理到 {rep['pages']} 页, 按降级计")

    text = build_report(pdf, cfg, rep, mdst, mdrep, pstats,
                        {"md": md_path, "pdf": sp_path, "fused": fused_path},
                        timing, decisions, empty_pages,
                        failed_pages, degraded, npages, suspect_pages,
                        single_engine_pages)
    try:
        write_text(report_path, text, cfg.force or cfg.resume)
    except BookError as e:                       # 报告写不了不算整份失败
        log(f"  ⚠ 质量报告未写出: {e}")
        report_path = None

    rec.update(status="ok", pages=rep["pages"], lines=rep["lines"],
               divergent_rate=rep["divergent_rate"],
               single_rate=rep["single_source_rate"],
               low_conf=rep["low_conf_count"],
               retrieval=(pstats or {}).get("retrieval"), embedded=bool(pstats),
               md=md_path, searchable=sp_path, report=report_path,
               failed_pages=failed_pages, native_suspect=suspect_pages,
               repaired=repaired,
               degraded=degraded, seconds=time.time() - t_all)
    log(f"  {'⚠' if degraded else '✓'} 完成 {rec['seconds']:.1f}s"
        + (f"   质量报告 {report_path}" if report_path else ""))
    if pstats and pstats.get("retrieval") is not None \
            and pstats["retrieval"] < pstats["min_retrieval"]:
        log(f"  ⚠ 取回率 {pstats['retrieval']:.4f} 低于阈值 "
            f"{pstats['min_retrieval']}, 见报告")
    return rec


# ============================ 批处理 ============================

def run(cfg: Config) -> int:
    pdfs = find_pdfs(cfg.input)
    if not pdfs:
        log(f"{cfg.input} 下没有 PDF。把扫描件放进去再跑。")
        return 0

    log(f"输入 {cfg.input}   共 {len(pdfs)} 份 PDF")
    log(f"输出 {cfg.outdir}   中间产物 {cfg.workdir}")
    if cfg.glossary:
        log(f"术语表 {len(cfg.glossary)} 条 <- {cfg.glossary_path}")
        log("  ⚠ 术语表是无词边界的纯子串替换, 书籍线没有人工校对兜底 —— "
            "改了哪些字见报告的「术语表改写明细」")
    else:
        log("术语表: 不启用(默认; 要用加 --glossary PATH)")

    t0 = time.time()
    recs: list[dict] = []
    for i, pdf in enumerate(pdfs, 1):
        try:
            recs.append(process_one(pdf, cfg, f"{i}/{len(pdfs)}"))
        except KeyboardInterrupt:
            log("\n已中断。")
            raise
        except BookError as e:
            log(f"  ✗ 失败: {e}")
            recs.append({"pdf": pdf, "stem": pdf.stem, "status": "failed",
                         "error": str(e)})
        except SystemExit as e:              # 子模块的「拒绝覆盖」等退出
            log(f"  ✗ 失败: {e}")
            recs.append({"pdf": pdf, "stem": pdf.stem, "status": "failed",
                         "error": str(e)})
        except Exception as e:               # noqa: BLE001  单份失败不拖垮整批
            log(f"  ✗ 失败: {type(e).__name__}: {e}")
            traceback.print_exc(file=sys.stderr)
            recs.append({"pdf": pdf, "stem": pdf.stem, "status": "failed",
                         "error": f"{type(e).__name__}: {e}"})

    ok = [r for r in recs if r["status"] == "ok"]
    skipped = [r for r in recs if r["status"] == "skipped"]
    failed = [r for r in recs if r["status"] == "failed"]
    degraded = [r for r in ok if r.get("degraded")]

    log("")
    log("══════ 汇总 ══════")
    log(f"成功 {len(ok)}(其中降级 {len(degraded)})   跳过 {len(skipped)}   "
        f"失败 {len(failed)}   总耗时 {time.time() - t0:.1f}s")
    for r in ok:
        ret = (f"{r['retrieval']:.4f}" if r["retrieval"] is not None
               else ("无嵌字" if r.get("embedded") else "复用"))
        log(f"  {'⚠' if r.get('degraded') else '✓'} {r['stem']}: "
            f"{r['pages']} 页 {r['lines']} 行   "
            f"分歧 {r['divergent_rate'] * 100:.1f}%   单源 {r['single_rate'] * 100:.1f}%"
            f"   取回 {ret}   {r['seconds']:.1f}s")
        for d in r.get("degraded") or ():
            log(f"      ⚠ {d}")
    for r in skipped:
        log(f"  - {r['stem']}: 跳过(产物已存在)")
    for r in failed:
        log(f"  ✗ {r['stem']}: {r['error']}")
    if ok:
        log(f"产物在 {cfg.outdir}, 质量报告在 {cfg.workdir}/<名>.report.md")
    if degraded:
        log(f"⚠ {len(degraded)} 份有降级(内容可能缺失), 退出码 3 —— "
            f"逐份看报告首屏的降级清单, 别直接当成稿用。")
    if failed:
        return 1
    return 3 if degraded else 0


# ==================== 可编程入口(GUI 用, CLI 不走这里) ====================

def run_batch(cfg: Config, pdfs: list[Path] | None = None,
              on_event=None, should_cancel=None) -> dict:
    """和 run() 同一条流水线, 但接受显式文件清单、发事件、可中断。

    run() 是 CLI 的入口(扫 cfg.input 目录 + 往 stderr 打汇总), 一个字没动。
    run_batch 是 GUI 的入口: 文件可以来自任意目录(用户在面板里逐个挑的),
    进度以事件形式送出, should_cancel() 返回 True 就在最近的检查点停下。

    pdfs=None 时退回扫 cfg.input 目录(与 CLI 一致)。

    事件契约 —— on_event 收到的永远是一个 dict, 必有 "type", 除 batch_* 外
    必有 "stem" / "pdf":

      batch_start  total, files:[str]            一批开始
      file_start   index(1 起), total, name      某份开始(index/total 是文件序号)
      pages        pages:int, repaired:bool      preflight 拿到页数
      stage        stage, step, steps, label     阶段切换
                   stage ∈ ocr|fuse|markdown|embed
      progress     engine, done, total           OCR 逐页(engine=Vision|RapidOCR)
      file_done    index, total, status, record  某份结束
                   status ∈ ok|degraded|skipped|failed|cancelled
      batch_done   ok, degraded, skipped, failed, cancelled,
                   seconds, exit_code, records

    record(file_done / batch_done 里的那个 dict)的键与 process_one 的返回值
    一致, 另外 pdf/md/searchable/report 一律是 str(方便跨线程、跨进程传):
      stem, status, pages, lines, divergent_rate, single_rate, low_conf,
      retrieval, md, searchable, report, degraded:[str], seconds, error

    返回值 = batch_done 那个 dict。退出码语义与 run() 相同:
      0 全成功 / 1 有失败 / 3 全跑完但有降级。被取消返回 130。
    """
    def fire(kind: str, **kw) -> None:
        if on_event is not None:
            on_event({"type": kind, **kw})

    def flatten(r: dict) -> dict:
        out = dict(r)
        for k in ("pdf", "md", "searchable", "report"):
            if out.get(k) is not None:
                out[k] = str(out[k])
        out["degraded"] = list(out.get("degraded") or ())
        return out

    todo = list(pdfs) if pdfs is not None else find_pdfs(cfg.input)
    cfg.outdir.mkdir(parents=True, exist_ok=True)
    cfg.workdir.mkdir(parents=True, exist_ok=True)

    fire("batch_start", total=len(todo), files=[str(p) for p in todo],
         outdir=str(cfg.outdir), workdir=str(cfg.workdir))
    log(f"输出 {cfg.outdir}   中间产物 {cfg.workdir}")
    if cfg.glossary:
        log(f"术语表 {len(cfg.glossary)} 条 <- {cfg.glossary_path}")
        log("  ⚠ 术语表是无词边界的纯子串替换, 书籍线没有人工校对兜底 —— "
            "改了哪些字见报告的「术语表改写明细」")

    t0 = time.time()
    recs: list[dict] = []
    cancelled = False
    for i, pdf in enumerate(todo, 1):
        if should_cancel is not None and should_cancel():
            cancelled = True
        if cancelled:                       # 剩下的全部记成「已取消」
            rec = {"pdf": pdf, "stem": pdf.stem, "status": "cancelled"}
            recs.append(rec)
            fire("file_done", index=i, total=len(todo), status="cancelled",
                 record=flatten(rec))
            continue
        fire("file_start", index=i, total=len(todo), name=pdf.name,
             pdf=str(pdf), stem=pdf.stem)
        try:
            rec = process_one(pdf, cfg, f"{i}/{len(todo)}", on_event, should_cancel)
        except Cancelled:
            log("  ✗ 已取消")
            cancelled = True
            rec = {"pdf": pdf, "stem": pdf.stem, "status": "cancelled"}
        except (BookError, SystemExit) as e:
            log(f"  ✗ 失败: {e}")
            rec = {"pdf": pdf, "stem": pdf.stem, "status": "failed",
                   "error": str(e)}
        except KeyboardInterrupt:           # 和 run() 一样不吞
            raise
        except Exception as e:              # noqa: BLE001  单份失败不拖垮整批
            log(f"  ✗ 失败: {type(e).__name__}: {e}")
            traceback.print_exc(file=sys.stderr)
            rec = {"pdf": pdf, "stem": pdf.stem, "status": "failed",
                   "error": f"{type(e).__name__}: {e}"}
        recs.append(rec)
        st = rec["status"]
        if st == "ok" and rec.get("degraded"):
            st = "degraded"
        fire("file_done", index=i, total=len(todo), status=st,
             record=flatten(rec))

    ok = [r for r in recs if r["status"] == "ok"]
    degraded = [r for r in ok if r.get("degraded")]
    summary = {
        "ok": len(ok) - len(degraded), "degraded": len(degraded),
        "skipped": sum(1 for r in recs if r["status"] == "skipped"),
        "failed": sum(1 for r in recs if r["status"] == "failed"),
        "cancelled": cancelled,
        "seconds": time.time() - t0,
        "records": [flatten(r) for r in recs],
    }
    summary["exit_code"] = (130 if cancelled else
                            1 if summary["failed"] else
                            3 if degraded else 0)
    log(f"══ 本批结束: 成功 {summary['ok']}  降级 {summary['degraded']}  "
        f"跳过 {summary['skipped']}  失败 {summary['failed']}"
        + ("  (已取消)" if cancelled else "")
        + f"   {summary['seconds']:.1f}s")
    fire("batch_done", **summary)
    return summary


# ============================ CLI ============================

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="run_books.py",
        description="书籍扫描件批处理: input/*.pdf -> 段落化 Markdown + 可搜索 PDF")
    ap.add_argument("--input", default=str(ROOT / "input"), help="输入目录")
    ap.add_argument("--outdir", default=None, help="输出目录, 默认 output/")
    ap.add_argument("--work-dir", default=None,
                    help="中间产物目录, 默认 work/(给了 --outdir 时为 <outdir>/work)")
    ap.add_argument("--dpi", type=float, default=DEFAULT_DPI,
                    help=f"基准渲染分辨率, 默认 {DEFAULT_DPI}"
                         f"(内嵌图分辨率更高的页会自动提升)")
    ap.add_argument("--no-native-dpi", dest="native_dpi", action="store_false",
                    help="不按内嵌图原生分辨率提升 dpi —— 严格用 --dpi 的值"
                         "(几百页的大书想换时间时用; 默认是取两者里高的那个)")
    ap.add_argument("--max-dpi", type=float, default=None,
                    help="渲染分辨率上限(默认用 book_render 的 MAX_DPI)。"
                         "几百页的大书用它压住磁盘峰值和耗时")
    ap.add_argument("--pages", default=None, metavar="N|A-B",
                    help="只处理这些页(如 1-10) —— 大书先跑十来页试水, "
                         "看清质量和速度再决定跑整本")
    ap.add_argument("--force-ocr", action="store_true",
                    help="无视已有的文字层, 一律当扫描页重新识别。"
                         "复印机/网盘预览写过的垃圾文字层会被当成原生文字跳过 OCR, "
                         "产出整本垃圾 —— 发现 md 是乱码就加这个")
    ap.add_argument("--allow-repaired", action="store_true",
                    help="结构损坏(MuPDF 自动修复才打开)的 PDF 也尽力处理。"
                         "默认直接不处理; 加了这个结果按降级计(退出码 3)")
    ap.add_argument("--jobs", type=int, default=None,
                    help=f"Vision 并发数, 默认 {default_jobs()}")
    ap.add_argument("--engine", choices=("both",) + ENGINES, default="both")
    ap.add_argument("--force", action="store_true",
                    help="重做并覆盖已有产物")
    ap.add_argument("--clobber", action="store_true",
                    help="配合 --force: 连不是书籍线产出的同名文件也覆盖"
                         "(会毁掉剧本线成稿, 想清楚再用)")
    ap.add_argument("--resume", action="store_true",
                    help="复用已有且合契约的中间产物, 缺什么补什么, 不覆盖")
    ap.add_argument("--keep-pages", action="store_true",
                    help="保留渲染出的页图(默认识别完即删)")
    ap.add_argument("--no-page-marks", dest="page_marks", action="store_false",
                    help="Markdown 里不插 <!-- page N --> 标记")
    ap.add_argument("--glossary", default=None, metavar="PATH",
                    help="显式启用术语表(默认**不启用**)。术语表是无词边界的纯"
                         "子串替换, 而书籍线没有人工校对兜底: 项目里的 "
                         "config/glossary.txt 是按剧本整理的, 套到别的书上会把"
                         "本来读对的字改错(实测 大谷翔平 -> 大爷翔平)。"
                         "确认这张表适合这本书再给路径")
    ap.add_argument("--no-glossary", action="store_true",
                    help="(不启用术语表已经是默认行为, 这个开关保留只为兼容旧命令行。"
                         "和 --glossary 一起给时以它为准 —— 即不启用, 偏安全的那头)")
    ap.add_argument("--subset", dest="subset", action="store_true", default=None,
                    help="强制子集化嵌入的字体(源文档本来就有文字层时默认不做, "
                         "会多出约 1.6MB 固定开销)")
    ap.add_argument("--no-subset", dest="subset", action="store_false",
                    help="不子集化(体积换稳妥)")
    ap.add_argument("--min-retrieval", type=float,
                    default=book_pdf.DEFAULT_MIN_RETRIEVAL,
                    help="可搜索 PDF 的文字取回率告警阈值")
    a = ap.parse_args(argv)

    outdir = Path(a.outdir).expanduser() if a.outdir else ROOT / "output"
    if a.work_dir:
        workdir = Path(a.work_dir).expanduser()
    else:
        #  指定了 --outdir(测试/另存) 时, 中间产物也跟着走, 免得写进项目 work/
        workdir = ROOT / "work" if outdir == ROOT / "output" else outdir / "work"

    #  术语表 opt-in: 不给 --glossary 就一条规则都不加载。--no-glossary 现在是
    #  无操作(默认就不加载), 保留只为让旧命令行还能跑。
    gpath = None
    glossary: list = []
    if a.glossary and not a.no_glossary:
        gpath = Path(a.glossary).expanduser()
        if not gpath.is_file():
            raise SystemExit(f"--glossary 指的文件不存在: {gpath}")
        glossary = load_glossary(gpath)
        if not glossary:
            log(f"⚠ {gpath} 里没有可用规则, 术语表等于没启用")

    if a.pages and a.resume:
        log("⚠ --pages 和 --resume 一起用: 复用的 JSON 是上次的页范围, 注意对齐")

    cfg = Config(
        input=Path(a.input).expanduser(), outdir=outdir.resolve(),
        workdir=workdir.resolve(), dpi=a.dpi, jobs=a.jobs, engine=a.engine,
        native_dpi=a.native_dpi, max_dpi=a.max_dpi, pages=a.pages,
        force_ocr=a.force_ocr, allow_repaired=a.allow_repaired,
        force=a.force, resume=a.resume, clobber=a.clobber,
        keep_pages=a.keep_pages,
        page_marks=a.page_marks, min_retrieval=a.min_retrieval, subset=a.subset,
        glossary_path=gpath, glossary=glossary,
    )
    cfg.outdir.mkdir(parents=True, exist_ok=True)
    cfg.workdir.mkdir(parents=True, exist_ok=True)
    try:
        return run(cfg)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
