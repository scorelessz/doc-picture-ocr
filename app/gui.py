#!/usr/bin/env python3
"""界面。Tk 只在主线程, 流水线在工作线程, 中间隔一个 queue + after() 轮询。

设计取向是「不读文档就会用」: 打开就是一张空队列 + 两个加文件的按钮 + 一个
开始按钮, 参数全有默认值并且折叠起来。跑起来之后最该看的两件事 ——
**现在到第几页**和**哪一份不对劲** —— 放在最显眼的位置。
"""
from __future__ import annotations

import queue
import subprocess
import threading
import time
from pathlib import Path

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from . import settings
from .paths import default_outdir, describe, vision_bin
from .pipeline import Job, Runner, stage_fraction

APP_TITLE = "文档图片 OCR · 扫描件转可搜索 PDF 和 Markdown"

#  表格状态文案。排队/处理中之外的都带符号, 扫一眼就知道哪份要看。
ST_QUEUED = "排队"
ST_RUNNING = "处理中"
ST_OK = "✓ 完成"
ST_DEGRADED = "⚠ 降级"
ST_FAILED = "✗ 失败"
ST_SKIPPED = "— 跳过"
ST_CANCELLED = "— 已取消"

_TAGS = {
    ST_OK: ("ok", "#1b5e20", "#eaf5ea"),
    ST_DEGRADED: ("degraded", "#8a4b00", "#fff3e0"),
    ST_FAILED: ("failed", "#9b1c1c", "#fdecea"),
    ST_SKIPPED: ("skipped", "#666666", ""),
    ST_CANCELLED: ("cancelled", "#666666", ""),
    ST_RUNNING: ("running", "#0b4f9e", "#e8f1fb"),
    ST_QUEUED: ("queued", "", ""),
}


def fmt_secs(s: float) -> str:
    if s <= 0:
        return ""
    m, sec = divmod(int(s + 0.5), 60)
    return f"{m}:{sec:02d}" if m else f"{sec}s"


def reveal(path: Path) -> None:
    """在 Finder 里打开(目录)或选中(文件)。中文/空格/括号都按参数传, 不拼 shell。"""
    p = Path(path)
    try:
        if p.is_dir():
            subprocess.Popen(["open", str(p)])
        elif p.exists():
            subprocess.Popen(["open", "-R", str(p)])
        else:
            subprocess.Popen(["open", str(p.parent)])
    except OSError as e:
        messagebox.showwarning("打不开", f"{p}\n{e}")


def open_file(path: Path) -> None:
    try:
        subprocess.Popen(["open", str(path)])
    except OSError as e:
        messagebox.showwarning("打不开", f"{path}\n{e}")


# ---------------------------------------------------------------- 折叠区

class Collapsible(ttk.Frame):
    """标题行点一下展开/收起。body 是一个普通 Frame, 调用方往里放东西。"""

    def __init__(self, master, text: str, open_: bool = False, **kw):
        super().__init__(master, **kw)
        self.columnconfigure(0, weight=1)
        self._open = tk.BooleanVar(value=open_)
        self._text = text
        self.header = ttk.Button(self, style="Toolbutton", command=self.toggle)
        self.header.grid(row=0, column=0, sticky="we")
        self.body = ttk.Frame(self, padding=(12, 6, 8, 8))
        self.body.grid(row=1, column=0, sticky="nsew")
        self.rowconfigure(1, weight=1)
        self._sync()

    def toggle(self) -> None:
        self._open.set(not self._open.get())
        self._sync()

    def set_open(self, v: bool) -> None:
        self._open.set(bool(v))
        self._sync()

    @property
    def is_open(self) -> bool:
        return bool(self._open.get())

    def _sync(self) -> None:
        self.header.configure(text=("▾  " if self._open.get() else "▸  ") + self._text)
        if self._open.get():
            self.body.grid()
        else:
            self.body.grid_remove()


# ---------------------------------------------------------------- 主窗口

class App:
    POLL_MS = 80

    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.cfg = settings.load()
        self.runner: Runner | None = None
        self.rows: list[dict] = []          # 每份文件一条: path/iid/status/record…
        self.by_path: dict[str, dict] = {}
        self.cur: dict | None = None
        self.batch_t0 = 0.0
        self._probe_q: queue.Queue[tuple[str, int | None]] = queue.Queue()

        root.title(APP_TITLE)
        root.minsize(900, 560)
        geo = str(self.cfg.get("window") or "")
        root.geometry(geo if geo else "1120x740")
        root.protocol("WM_DELETE_WINDOW", self.on_close)

        self._style()
        self._build()
        self._try_dnd()
        self._update_buttons()
        self.log(describe())
        if not vision_bin().exists():
            self.log("⚠ 找不到 bin/vision-ocr —— Vision 引擎不可用。"
                     "重新编译: swiftc -O src/vision_ocr.swift -o bin/vision-ocr")
            self.set_status("⚠ 缺 bin/vision-ocr, 只能用 RapidOCR 单引擎", bad=True)
        self.root.after(self.POLL_MS, self._pump)

    # ------------------------------------------------------------ 外观
    def _style(self) -> None:
        s = ttk.Style()
        for t in ("aqua", "clam"):          # aqua = macOS 原生观感
            try:
                s.theme_use(t)
                break
            except tk.TclError:
                continue
        try:
            s.configure("Treeview", rowheight=24)
        except tk.TclError:
            pass

    # ------------------------------------------------------------ 布局
    def _build(self) -> None:
        r = self.root
        r.columnconfigure(0, weight=1)
        r.rowconfigure(1, weight=3)         # 队列表格吃掉多余高度

        # ---- 工具条
        bar = ttk.Frame(r, padding=(12, 10, 12, 6))
        bar.grid(row=0, column=0, sticky="we")
        ttk.Button(bar, text="添加文件…", command=self.add_files).pack(side="left")
        ttk.Button(bar, text="添加文件夹…", command=self.add_folder).pack(side="left", padx=(6, 0))
        ttk.Button(bar, text="移除所选", command=self.remove_selected).pack(side="left", padx=(16, 0))
        ttk.Button(bar, text="清空", command=self.clear_all).pack(side="left", padx=(6, 0))

        self.btn_cancel = ttk.Button(bar, text="取消", command=self.cancel, state="disabled")
        self.btn_cancel.pack(side="right")
        self.btn_start = ttk.Button(bar, text="▶  开始识别", command=self.start)
        self.btn_start.pack(side="right", padx=(0, 8))

        # ---- 队列表格
        box = ttk.Frame(r, padding=(12, 0, 12, 0))
        box.grid(row=1, column=0, sticky="nsew")
        box.columnconfigure(0, weight=1)
        box.rowconfigure(0, weight=1)

        cols = ("name", "pages", "status", "stage", "time", "out")
        self.tree = ttk.Treeview(box, columns=cols, show="headings", selectmode="extended")
        for c, t, w, anchor in (
            ("name", "文件", 300, "w"),
            ("pages", "页数", 60, "e"),
            ("status", "状态", 90, "w"),
            ("stage", "当前阶段 / 说明", 300, "w"),
            ("time", "耗时", 70, "e"),
            ("out", "产物", 160, "w"),
        ):
            self.tree.heading(c, text=t)
            self.tree.column(c, width=w, anchor=anchor,
                             stretch=(c in ("name", "stage")))
        self.tree.grid(row=0, column=0, sticky="nsew")
        sb = ttk.Scrollbar(box, orient="vertical", command=self.tree.yview)
        sb.grid(row=0, column=1, sticky="ns")
        self.tree.configure(yscrollcommand=sb.set)

        for tag, fg, bg in _TAGS.values():
            if tag:
                kw = {}
                if fg:
                    kw["foreground"] = fg
                if bg:
                    kw["background"] = bg
                if kw:
                    self.tree.tag_configure(tag, **kw)

        self.tree.bind("<Double-1>", self.on_row_activate)
        self.tree.bind("<Button-2>", self._popup)
        self.tree.bind("<Control-Button-1>", self._popup)
        self.tree.bind("<<TreeviewSelect>>", lambda e: self._update_buttons())

        self.menu = tk.Menu(r, tearoff=0)
        self.menu.add_command(label="打开 Markdown", command=lambda: self.open_artifact("md"))
        self.menu.add_command(label="打开可搜索 PDF", command=lambda: self.open_artifact("searchable"))
        self.menu.add_command(label="查看质量报告", command=lambda: self.open_artifact("report"))
        self.menu.add_separator()
        self.menu.add_command(label="在 Finder 里显示", command=self.reveal_selected)
        self.menu.add_command(label="从队列移除", command=self.remove_selected)

        hint = ttk.Label(box, foreground="#777",
                         text="把 PDF 拖进来, 或用上面的「添加文件」。"
                              "双击一行打开它的 Markdown; 右键看更多。")
        hint.grid(row=1, column=0, sticky="w", pady=(6, 0))
        self.hint = hint

        # ---- 进度
        pr = ttk.Frame(r, padding=(12, 10, 12, 4))
        pr.grid(row=2, column=0, sticky="we")
        pr.columnconfigure(1, weight=1)

        ttk.Label(pr, text="总体").grid(row=0, column=0, sticky="w", padx=(0, 8))
        self.pb_all = ttk.Progressbar(pr, mode="determinate", maximum=1000)
        self.pb_all.grid(row=0, column=1, sticky="we")
        self.lb_all = ttk.Label(pr, text="就绪", width=22, anchor="e")
        self.lb_all.grid(row=0, column=2, sticky="e", padx=(8, 0))

        ttk.Label(pr, text="当前").grid(row=1, column=0, sticky="w", padx=(0, 8), pady=(6, 0))
        self.pb_one = ttk.Progressbar(pr, mode="determinate", maximum=1000)
        self.pb_one.grid(row=1, column=1, sticky="we", pady=(6, 0))
        self.lb_one = ttk.Label(pr, text="", width=22, anchor="e")
        self.lb_one.grid(row=1, column=2, sticky="e", padx=(8, 0), pady=(6, 0))

        self.lb_detail = ttk.Label(pr, text="", foreground="#555")
        self.lb_detail.grid(row=2, column=0, columnspan=3, sticky="w", pady=(6, 0))

        # ---- 参数区
        self.params = Collapsible(r, "参数（默认值适用于绝大多数扫描件）",
                                  open_=bool(self.cfg.get("params_open")))
        self.params.grid(row=3, column=0, sticky="we", padx=12, pady=(6, 0))
        self._build_params(self.params.body)

        # ---- 日志区
        r.rowconfigure(4, weight=2)
        self.logbox = Collapsible(r, "运行日志（出错时的完整信息在这里）",
                                  open_=bool(self.cfg.get("log_open")))
        self.logbox.grid(row=4, column=0, sticky="nsew", padx=12, pady=(6, 0))
        lb = self.logbox.body
        lb.columnconfigure(0, weight=1)
        lb.rowconfigure(0, weight=1)
        self.text = tk.Text(lb, height=10, wrap="none", undo=False,
                            font=("Menlo", 11))
        self.text.grid(row=0, column=0, sticky="nsew")
        lsb = ttk.Scrollbar(lb, orient="vertical", command=self.text.yview)
        lsb.grid(row=0, column=1, sticky="ns")
        self.text.configure(yscrollcommand=lsb.set, state="disabled")
        row = ttk.Frame(lb)
        row.grid(row=1, column=0, columnspan=2, sticky="we", pady=(6, 0))
        ttk.Button(row, text="复制全部", command=self.copy_log).pack(side="left")
        ttk.Button(row, text="清空日志", command=self.clear_log).pack(side="left", padx=(6, 0))
        self.autoscroll = tk.BooleanVar(value=True)
        ttk.Checkbutton(row, text="自动滚到底", variable=self.autoscroll).pack(side="left", padx=(12, 0))

        # ---- 状态条
        self.status = ttk.Label(r, text="就绪", anchor="w", padding=(12, 6))
        self.status.grid(row=5, column=0, sticky="we")

    def _build_params(self, f: ttk.Frame) -> None:
        c = self.cfg
        f.columnconfigure(1, weight=1)
        rowi = 0

        # 输出目录
        ttk.Label(f, text="输出目录").grid(row=rowi, column=0, sticky="w", pady=3, padx=(0, 10))
        self.v_outdir = tk.StringVar(value=str(settings.resolved_outdir(c)))
        e = ttk.Entry(f, textvariable=self.v_outdir)
        e.grid(row=rowi, column=1, sticky="we", pady=3)
        ttk.Button(f, text="选择…", command=self.pick_outdir).grid(row=rowi, column=2, padx=(6, 0))
        ttk.Button(f, text="打开", command=lambda: reveal(Path(self.v_outdir.get()))
                   ).grid(row=rowi, column=3, padx=(6, 0))
        rowi += 1
        ttk.Label(f, text="中间产物和质量报告放在 输出目录/work/ 下",
                  foreground="#777").grid(row=rowi, column=1, sticky="w")
        rowi += 1

        # dpi 一行
        ttk.Label(f, text="分辨率").grid(row=rowi, column=0, sticky="w", pady=3, padx=(0, 10))
        g = ttk.Frame(f)
        g.grid(row=rowi, column=1, columnspan=3, sticky="w", pady=3)
        ttk.Label(g, text="基准 dpi").pack(side="left")
        self.v_dpi = tk.StringVar(value=f"{c['dpi']:g}")
        ttk.Spinbox(g, from_=72, to=1200, increment=50, width=7,
                    textvariable=self.v_dpi).pack(side="left", padx=(4, 14))
        ttk.Label(g, text="上限 dpi").pack(side="left")
        self.v_maxdpi = tk.StringVar(value=(f"{c['max_dpi']:g}" if c["max_dpi"] else ""))
        ttk.Entry(g, width=7, textvariable=self.v_maxdpi).pack(side="left", padx=(4, 4))
        ttk.Label(g, text="(留空=不限)", foreground="#777").pack(side="left", padx=(0, 14))
        self.v_native = tk.BooleanVar(value=bool(c["native_dpi"]))
        ttk.Checkbutton(g, text="内嵌图更清晰时自动提高", variable=self.v_native).pack(side="left")
        rowi += 1

        # 引擎 / 并发 / 页范围
        ttk.Label(f, text="识别").grid(row=rowi, column=0, sticky="w", pady=3, padx=(0, 10))
        g = ttk.Frame(f)
        g.grid(row=rowi, column=1, columnspan=3, sticky="w", pady=3)
        ttk.Label(g, text="引擎").pack(side="left")
        self.v_engine = tk.StringVar(value=c["engine"])
        cb = ttk.Combobox(g, width=22, state="readonly", textvariable=self.v_engine,
                          values=("both", "vision", "rapidocr"))
        cb.pack(side="left", padx=(4, 4))
        ttk.Label(g, text="(both=双引擎交叉验证, 推荐)", foreground="#777").pack(side="left", padx=(0, 14))
        ttk.Label(g, text="Vision 并发").pack(side="left")
        self.v_jobs = tk.StringVar(value=(str(c["jobs"]) if c["jobs"] else ""))
        ttk.Entry(g, width=5, textvariable=self.v_jobs).pack(side="left", padx=(4, 14))
        ttk.Label(g, text="页范围").pack(side="left")
        self.v_pages = tk.StringVar(value=c["pages"])
        ttk.Entry(g, width=10, textvariable=self.v_pages).pack(side="left", padx=(4, 4))
        ttk.Label(g, text="(如 1-20, 留空=整本)", foreground="#777").pack(side="left")
        rowi += 1

        # 已存在产物
        ttk.Label(f, text="已有产物").grid(row=rowi, column=0, sticky="w", pady=3, padx=(0, 10))
        g = ttk.Frame(f)
        g.grid(row=rowi, column=1, columnspan=3, sticky="w", pady=3)
        self.v_exist = tk.StringVar(value=c["on_exist"])
        for val, txt in (("skip", "跳过（默认）"), ("resume", "续跑：缺什么补什么"),
                         ("redo", "重做：覆盖已有产物")):
            ttk.Radiobutton(g, text=txt, value=val, variable=self.v_exist).pack(side="left", padx=(0, 14))
        rowi += 1

        # 开关
        ttk.Label(f, text="其他").grid(row=rowi, column=0, sticky="w", pady=3, padx=(0, 10))
        g = ttk.Frame(f)
        g.grid(row=rowi, column=1, columnspan=3, sticky="w", pady=3)
        self.v_forceocr = tk.BooleanVar(value=bool(c["force_ocr"]))
        ttk.Checkbutton(g, text="无视已有文字层，一律重新识别",
                        variable=self.v_forceocr).pack(side="left", padx=(0, 14))
        self.v_keep = tk.BooleanVar(value=bool(c["keep_pages"]))
        ttk.Checkbutton(g, text="保留页图", variable=self.v_keep).pack(side="left", padx=(0, 14))
        self.v_marks = tk.BooleanVar(value=bool(c["page_marks"]))
        ttk.Checkbutton(g, text="Markdown 里插页码标记", variable=self.v_marks).pack(side="left", padx=(0, 14))
        self.v_repaired = tk.BooleanVar(value=bool(c["allow_repaired"]))
        ttk.Checkbutton(g, text="损坏的 PDF 也尽力处理", variable=self.v_repaired).pack(side="left")
        rowi += 1

        # 术语表
        ttk.Label(f, text="术语表").grid(row=rowi, column=0, sticky="w", pady=3, padx=(0, 10))
        g = ttk.Frame(f)
        g.grid(row=rowi, column=1, columnspan=3, sticky="we", pady=3)
        g.columnconfigure(0, weight=1)
        self.v_gloss = tk.StringVar(value=c["glossary"])
        ttk.Entry(g, textvariable=self.v_gloss).grid(row=0, column=0, sticky="we")
        ttk.Button(g, text="选择…", command=self.pick_glossary).grid(row=0, column=1, padx=(6, 0))
        ttk.Button(g, text="清除", command=lambda: self.v_gloss.set("")).grid(row=0, column=2, padx=(6, 0))
        rowi += 1
        ttk.Label(f, foreground="#8a4b00",
                  text="默认不启用。术语表是无词边界的纯替换，这条线没有人工校对兜底："
                       "套错表会把本来读对的字改错（实测「大谷翔平」→「大爷翔平」）。"
                  ).grid(row=rowi, column=1, columnspan=3, sticky="w")
        rowi += 1

        ttk.Button(f, text="恢复默认值", command=self.reset_params
                   ).grid(row=rowi, column=1, sticky="w", pady=(8, 0))

    # ------------------------------------------------------------ 拖拽(可选)
    def _try_dnd(self) -> None:
        """tkinterdnd2 装了就支持拖拽, 没装就当没这回事 —— 绝不因此报错。

        这个库要额外的 Tcl 扩展, 打包容易出事, 所以是纯可选项: 上面的
        「添加文件」按钮永远能用, 功能不依赖拖拽。
        """
        try:
            from tkinterdnd2 import DND_FILES          # noqa: PLC0415
            self.tree.drop_target_register(DND_FILES)
            self.tree.dnd_bind("<<Drop>>", self._on_drop)
        except Exception as e:                          # noqa: BLE001
            self.log(f"（拖拽未启用: {type(e).__name__}。用「添加文件」按钮，功能一样。）")
            return
        self.hint.configure(text="把 PDF 或文件夹拖进来，或用上面的「添加文件」。"
                                 "双击一行打开它的 Markdown; 右键看更多。")
        self.log("（拖拽已启用）")

    def _on_drop(self, event) -> None:
        try:
            paths = self.root.tk.splitlist(event.data)   # 正确处理带空格的路径
        except tk.TclError:
            paths = str(event.data).split()
        found: list[Path] = []
        for s in paths:
            p = Path(s)
            if p.is_dir():
                found += self._pdfs_in(p)
            elif p.suffix.lower() == ".pdf":
                found.append(p)
        self.add_paths(found)

    # ------------------------------------------------------------ 队列
    @staticmethod
    def _pdfs_in(d: Path) -> list[Path]:
        """目录下的 PDF(不递归), 与 books.sh / find_pdfs 的口径一致。"""
        try:
            return sorted((p for p in d.iterdir()
                           if p.is_file() and not p.name.startswith(".")
                           and p.suffix.lower() == ".pdf"),
                          key=lambda p: p.name)
        except OSError:
            return []

    def add_files(self) -> None:
        init = self.cfg.get("last_dir") or str(Path.home())
        fs = filedialog.askopenfilenames(title="选择扫描件 PDF", initialdir=init,
                                         filetypes=[("PDF", "*.pdf"), ("所有文件", "*")])
        if fs:
            self.cfg["last_dir"] = str(Path(fs[0]).parent)
            self.add_paths([Path(f) for f in fs])

    def add_folder(self) -> None:
        init = self.cfg.get("last_dir") or str(Path.home())
        d = filedialog.askdirectory(title="选择装着扫描件的文件夹", initialdir=init)
        if not d:
            return
        self.cfg["last_dir"] = d
        found = self._pdfs_in(Path(d))
        if not found:
            messagebox.showinfo("没找到 PDF", f"{d}\n里没有 PDF 文件（只看这一层，不进子文件夹）。")
            return
        self.add_paths(found)

    def add_paths(self, paths: list[Path]) -> None:
        added = 0
        for p in paths:
            p = Path(p).expanduser()
            try:
                key = str(p.resolve())
            except OSError:
                key = str(p)
            if key in self.by_path:
                continue
            if not p.is_file():
                continue
            row = {"path": p, "key": key, "status": ST_QUEUED, "stage": "",
                   "pages": None, "seconds": 0.0, "record": None, "iid": "",
                   "frac": 0.0}
            row["iid"] = self.tree.insert("", "end", values=(p.name, "", ST_QUEUED, "", "", ""))
            self.rows.append(row)
            self.by_path[key] = row
            added += 1
            self._probe(row)
        if added:
            self.set_status(f"队列里 {len(self.rows)} 份")
        self._update_buttons()

    def _probe(self, row: dict) -> None:
        """后台数一下这份 PDF 多少页。

        不数的话总体进度条会**倒退**: 页数只在每份开工时才知道, 第一份 4 页跑到
        88% 时总权重是 4+4, 第二份一开工发现是 30 页, 同样的已完成量瞬间变成
        34 分之 3.5(实测 44% → 14%)。开个线程提前问清楚, 顺手也让用户在按
        「开始」之前就看到这批有多厚。
        """
        def work() -> None:
            n = None
            try:
                import pymupdf
                with pymupdf.open(row["path"]) as d:
                    n = d.page_count
            except Exception:                 # noqa: BLE001 数不出来就空着
                n = None
            self._probe_q.put((row["key"], n))

        threading.Thread(target=work, daemon=True).start()

    def remove_selected(self) -> None:
        if self.runner and self.runner.is_alive():
            messagebox.showinfo("正在处理", "跑完或取消之后再改队列。")
            return
        for iid in self.tree.selection():
            row = self._row_by_iid(iid)
            if row:
                self.rows.remove(row)
                self.by_path.pop(row["key"], None)
            self.tree.delete(iid)
        self._update_buttons()

    def clear_all(self) -> None:
        if self.runner and self.runner.is_alive():
            messagebox.showinfo("正在处理", "跑完或取消之后再改队列。")
            return
        for r in self.rows:
            self.tree.delete(r["iid"])
        self.rows.clear()
        self.by_path.clear()
        self._reset_progress()
        self._update_buttons()

    def _row_by_iid(self, iid: str) -> dict | None:
        for r in self.rows:
            if r["iid"] == iid:
                return r
        return None

    # ------------------------------------------------------------ 表格动作
    def _popup(self, event) -> None:
        iid = self.tree.identify_row(event.y)
        if iid:
            if iid not in self.tree.selection():
                self.tree.selection_set(iid)
            try:
                self.menu.tk_popup(event.x_root, event.y_root)
            finally:
                self.menu.grab_release()

    def _selected_row(self) -> dict | None:
        sel = self.tree.selection()
        return self._row_by_iid(sel[0]) if sel else None

    def on_row_activate(self, event) -> None:
        self.open_artifact("md")

    def open_artifact(self, kind: str) -> None:
        row = self._selected_row()
        if not row:
            return
        rec = row.get("record") or {}
        p = rec.get(kind)
        if not p:
            messagebox.showinfo("还没有", "这一份还没有产出这个文件。"
                                          "跑完之后再看；失败的原因在日志里。")
            return
        open_file(Path(p))

    def reveal_selected(self) -> None:
        row = self._selected_row()
        if not row:
            return
        rec = row.get("record") or {}
        target = rec.get("md") or rec.get("searchable")
        reveal(Path(target) if target else Path(self.v_outdir.get()))

    # ------------------------------------------------------------ 参数
    def pick_outdir(self) -> None:
        d = filedialog.askdirectory(title="产物放哪里", initialdir=self.v_outdir.get() or str(Path.home()))
        if d:
            self.v_outdir.set(d)

    def pick_glossary(self) -> None:
        f = filedialog.askopenfilename(title="选择术语表 (正确词 <- 错误1, 错误2)",
                                       filetypes=[("文本", "*.txt"), ("所有文件", "*")])
        if f:
            self.v_gloss.set(f)

    def reset_params(self) -> None:
        d = settings.DEFAULTS
        self.v_outdir.set(str(default_outdir()))
        self.v_dpi.set(f"{d['dpi']:g}")
        self.v_maxdpi.set("")
        self.v_native.set(d["native_dpi"])
        self.v_engine.set(d["engine"])
        self.v_jobs.set("")
        self.v_pages.set("")
        self.v_exist.set(d["on_exist"])
        self.v_forceocr.set(d["force_ocr"])
        self.v_keep.set(d["keep_pages"])
        self.v_marks.set(d["page_marks"])
        self.v_repaired.set(d["allow_repaired"])
        self.v_gloss.set("")

    def collect(self) -> dict:
        def num(s: str, default: float = 0.0) -> float:
            try:
                return float(str(s).strip())
            except ValueError:
                return default
        return {
            "outdir": self.v_outdir.get().strip(),
            "dpi": num(self.v_dpi.get(), 300.0) or 300.0,
            "max_dpi": num(self.v_maxdpi.get(), 0.0),
            "native_dpi": bool(self.v_native.get()),
            "engine": self.v_engine.get(),
            "jobs": int(num(self.v_jobs.get(), 0)),
            "on_exist": self.v_exist.get(),
            "pages": self.v_pages.get().strip(),
            "glossary": self.v_gloss.get().strip(),
            "force_ocr": bool(self.v_forceocr.get()),
            "keep_pages": bool(self.v_keep.get()),
            "page_marks": bool(self.v_marks.get()),
            "allow_repaired": bool(self.v_repaired.get()),
            "window": self.root.geometry(),
            "params_open": self.params.is_open,
            "log_open": self.logbox.is_open,
            "last_dir": self.cfg.get("last_dir", ""),
        }

    def persist(self) -> None:
        self.cfg.update(self.collect())
        settings.save(self.cfg)

    # ------------------------------------------------------------ 跑
    def start(self) -> None:
        if self.runner and self.runner.is_alive():
            return
        todo = [r for r in self.rows]
        if not todo:
            messagebox.showinfo("队列是空的", "先用「添加文件」或「添加文件夹」放几份 PDF 进来。")
            return

        c = self.collect()
        outdir = Path(c["outdir"]).expanduser() if c["outdir"] else default_outdir()
        try:
            outdir.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            messagebox.showerror("输出目录建不了", f"{outdir}\n{e}")
            return

        #  同名文件会写到同一个 output/<名>.md —— 先问清楚, 不要静默互相覆盖
        stems: dict[str, list[Path]] = {}
        for r in todo:
            stems.setdefault(r["path"].stem, []).append(r["path"])
        dup = {k: v for k, v in stems.items() if len(v) > 1}
        if dup:
            names = "\n".join(f"  {k}: " + " / ".join(str(p) for p in v)
                              for k, v in dup.items())
            messagebox.showerror(
                "文件名重复",
                "这些文件同名，产物会写到同一个地方、互相覆盖：\n\n" + names +
                "\n\n改名或者分两批跑。")
            return

        if c["glossary"]:
            if not Path(c["glossary"]).expanduser().is_file():
                messagebox.showerror("术语表不存在", c["glossary"])
                return
            if not messagebox.askyesno(
                    "确认启用术语表",
                    "术语表是无词边界的纯替换，书籍线没有人工校对兜底。\n"
                    "套错表会把本来读对的字改错。\n\n确认这张表适合这批书？"):
                return

        self.persist()
        for r in todo:
            #  pages 不清: 加进队列时已经探好了, 清掉总体进度条又要倒退
            r.update(status=ST_QUEUED, stage="", seconds=0.0, record=None,
                     frac=0.0, ocr={})
            if r.get("pages") is None:
                self._probe(r)
            self._paint(r)

        job = Job(
            files=[r["path"] for r in todo],
            outdir=outdir,
            dpi=c["dpi"],
            max_dpi=c["max_dpi"] or None,
            native_dpi=c["native_dpi"],
            engine=c["engine"],
            jobs=c["jobs"] or None,
            pages=c["pages"] or None,
            force=(c["on_exist"] == "redo"),
            resume=(c["on_exist"] == "resume"),
            keep_pages=c["keep_pages"],
            page_marks=c["page_marks"],
            force_ocr=c["force_ocr"],
            allow_repaired=c["allow_repaired"],
            glossary=Path(c["glossary"]).expanduser() if c["glossary"] else None,
        )
        self.batch_t0 = time.time()
        self.cur = None
        self.runner = Runner(job)
        self.log("")
        self.log(f"═══ 开始 {len(job.files)} 份 → {outdir} ═══")
        self.runner.start()
        self._update_buttons()
        self.set_status(f"正在处理 0/{len(job.files)}")

    def cancel(self) -> None:
        if self.runner and self.runner.is_alive():
            self.runner.cancel()
            self.btn_cancel.configure(text="取消中…", state="disabled")
            self.set_status("取消中…（正在清理本次渲染的页图）")

    # ------------------------------------------------------------ 事件轮询
    def _pump(self) -> None:
        while True:                          # 页数探测的结果(和有没有在跑无关)
            try:
                key, n = self._probe_q.get_nowait()
            except queue.Empty:
                break
            row = self.by_path.get(key)
            if row is not None and row.get("pages") is None:
                row["pages"] = n
                self._paint(row)

        r = self.runner
        if r is not None:
            n = 0
            while n < 400:                   # 一轮最多处理这么多, 不饿死界面
                try:
                    ev = r.events.get_nowait()
                except queue.Empty:
                    break
                n += 1
                try:
                    self._handle(ev)
                except Exception:            # noqa: BLE001 界面错不该停掉轮询
                    import traceback
                    self.log("界面处理事件出错:\n" + traceback.format_exc())
            if not r.is_alive() and r.events.empty():
                self._finish_if_needed()
        self.root.after(self.POLL_MS, self._pump)

    def _find(self, ev: dict) -> dict | None:
        p = ev.get("pdf")
        if not p:
            return self.cur
        row = self.by_path.get(p)
        if row:
            return row
        try:
            return self.by_path.get(str(Path(p).resolve()))
        except OSError:
            return None

    def _handle(self, ev: dict) -> None:
        t = ev.get("type")
        if t == "log":
            self.log(ev.get("line", ""))
            return
        if t == "crash":
            self.log("═══ 整批崩了 ═══")
            self.log(ev.get("traceback", ev.get("error", "")))
            self.logbox.set_open(True)
            self.set_status("✗ " + str(ev.get("error", "出错")), bad=True)
            return
        if t == "batch_start":
            self.pb_all["value"] = 0
            return
        if t == "file_start":
            row = self._find(ev)
            if row:
                self.cur = row
                row.update(status=ST_RUNNING, stage="准备…", t0=time.time(),
                           frac=0.0, ocr={})
                self._paint(row)
                self.tree.see(row["iid"])
            self._idx = (ev.get("index"), ev.get("total"))
            self._progress(row)
            return
        if t == "pages":
            row = self._find(ev)
            if row:
                row["pages"] = ev.get("pages")
                if ev.get("repaired"):
                    row["stage"] = "⚠ PDF 结构损坏，尽力处理"
                self._paint(row)
            return
        if t == "stage":
            row = self._find(ev)
            if row:
                row["stage"] = f"[{ev.get('step')}/{ev.get('steps')}] " + str(ev.get("label", ""))
                row["cur_stage"] = ev.get("stage")
                row["frac"] = stage_fraction(ev.get("stage"))
                self._paint(row)
                self._progress(row)
                self.lb_detail.configure(text=f"{row['path'].name} · {ev.get('label','')}")
            return
        if t == "progress":
            row = self._find(ev)
            if row:
                done, total = ev.get("done", 0), ev.get("total", 0)
                #  双引擎是**串行**跑的: 只看单个引擎的 done/total, 进度条会在
                #  Vision 跑完、RapidOCR 从头开始时倒退回去。两个引擎的页数加起来
                #  当分母, 条子才只往前走。
                row.setdefault("ocr", {})[ev.get("engine")] = done
                n = 2 if (self.runner and self.runner.job.engine == "both") else 1
                row["frac"] = stage_fraction("ocr", sum(row["ocr"].values()),
                                             total * n)
                row["stage"] = (f"[1/4] 渲染 + OCR · {ev.get('engine')} "
                                f"{done}/{total} 页")
                self._paint(row)
                self._progress(row)
                self.lb_detail.configure(
                    text=f"{row['path'].name} · {ev.get('engine')} 第 {done}/{total} 页")
            return
        if t == "file_done":
            self._on_file_done(ev)
            return
        if t == "batch_done":
            self._on_batch_done(ev)
            return

    def _on_file_done(self, ev: dict) -> None:
        row = self._find(ev)
        rec = ev.get("record") or {}
        st = ev.get("status")
        if row is None:
            return
        row["record"] = rec
        if st != "cancelled":
            row["frac"] = 1.0               # 取消的那份保持在它停下的位置,
                                            # 清零会让总体进度条在收尾时往回跳
        row["seconds"] = float(rec.get("seconds") or (time.time() - row.get("t0", time.time())))
        if st == "ok":
            row["status"], row["stage"] = ST_OK, self._ok_note(rec)
        elif st == "degraded":
            row["status"] = ST_DEGRADED
            row["stage"] = "⚠ " + "；".join(rec.get("degraded") or ["见质量报告"])
            self.logbox.set_open(True)
        elif st == "skipped":
            row["status"], row["stage"] = ST_SKIPPED, "产物已存在（参数里可改成重做/续跑）"
            row["frac"] = 1.0
        elif st == "cancelled":
            row["status"], row["stage"] = ST_CANCELLED, "未完成，产物没有写出"
        else:
            row["status"] = ST_FAILED
            row["stage"] = str(rec.get("error") or "失败，详见日志")
            self.logbox.set_open(True)
        self._paint(row)
        self._progress(None)

    @staticmethod
    def _ok_note(rec: dict) -> str:
        bits = []
        if rec.get("lines") is not None:
            bits.append(f"{rec['lines']} 行")
        r = rec.get("retrieval")
        if r is not None:
            bits.append(f"取回 {r:.4f}")
        d = rec.get("divergent_rate")
        if d is not None:
            bits.append(f"分歧 {d * 100:.1f}%")
        return "   ".join(bits)

    def _on_batch_done(self, ev: dict) -> None:
        if not ev.get("cancelled"):
            self.pb_all["value"] = 1000     # 取消时不假装跑完, 停在真实位置
        self.pb_one["value"] = 0
        self.lb_one.configure(text="")
        self.lb_detail.configure(text="")
        parts = [f"成功 {ev.get('ok', 0)}"]
        if ev.get("degraded"):
            parts.append(f"降级 {ev['degraded']}")
        if ev.get("skipped"):
            parts.append(f"跳过 {ev['skipped']}")
        if ev.get("failed"):
            parts.append(f"失败 {ev['failed']}")
        msg = "　".join(parts) + f"　用时 {fmt_secs(ev.get('seconds', 0))}"
        if ev.get("cancelled"):
            msg = "已取消。" + msg
        self.set_status(msg, bad=bool(ev.get("failed")),
                        warn=bool(ev.get("degraded")))
        self.lb_all.configure(text="完成" if not ev.get("cancelled") else "已取消")
        if ev.get("degraded"):
            self.log("⚠ 有降级项：产物可能缺内容，逐份看质量报告首屏的降级清单，"
                     "别直接当成稿用。")

    def _finish_if_needed(self) -> None:
        if self.runner is None:
            return
        self.runner = None
        self.btn_cancel.configure(text="取消")
        self._update_buttons()

    # ------------------------------------------------------------ 进度条
    def _progress(self, row: dict | None) -> None:
        if row is not None:
            self.pb_one["value"] = int(1000 * float(row.get("frac", 0.0)))
            pages = row.get("pages")
            self.lb_one.configure(
                text=f"{row['path'].name[:16]}" + (f" · {pages} 页" if pages else ""))
        #  总体: 按页数加权(页数未知的用已知页数的平均值顶上), 不是简单的份数比
        known = [r["pages"] for r in self.rows if r.get("pages")]
        avg = (sum(known) / len(known)) if known else 1.0
        tot = done = 0.0
        for r in self.rows:
            w = float(r.get("pages") or avg)
            tot += w
            done += w * float(r.get("frac", 0.0))
        frac = (done / tot) if tot else 0.0
        self.pb_all["value"] = int(1000 * frac)
        i, n = getattr(self, "_idx", (None, None))
        txt = f"{i}/{n} 份 · {frac * 100:.0f}%" if i else f"{frac * 100:.0f}%"
        if self.batch_t0 and frac > 0.03:
            left = (time.time() - self.batch_t0) * (1 - frac) / frac
            txt += f" · 还剩约 {fmt_secs(left)}"
        self.lb_all.configure(text=txt)

    def _reset_progress(self) -> None:
        self.pb_all["value"] = 0
        self.pb_one["value"] = 0
        self.lb_all.configure(text="就绪")
        self.lb_one.configure(text="")
        self.lb_detail.configure(text="")

    # ------------------------------------------------------------ 画一行
    def _paint(self, row: dict) -> None:
        rec = row.get("record") or {}
        out = ""
        if rec.get("md"):
            out = Path(rec["md"]).name
            if rec.get("searchable"):
                out += " + PDF"
        self.tree.item(row["iid"], values=(
            row["path"].name,
            row.get("pages") or "",
            row["status"],
            row.get("stage", ""),
            fmt_secs(row.get("seconds", 0.0)),
            out,
        ), tags=(_TAGS.get(row["status"], ("", "", ""))[0],))

    # ------------------------------------------------------------ 杂项
    def _update_buttons(self) -> None:
        busy = bool(self.runner and self.runner.is_alive())
        self.btn_start.configure(state=("disabled" if busy or not self.rows else "normal"))
        self.btn_cancel.configure(state=("normal" if busy and not
                                         (self.runner and self.runner.cancelled) else "disabled"))

    def set_status(self, text: str, bad: bool = False, warn: bool = False) -> None:
        self.status.configure(text=text,
                              foreground=("#9b1c1c" if bad else
                                          "#8a4b00" if warn else ""))

    def log(self, line: str) -> None:
        self.text.configure(state="normal")
        self.text.insert("end", line + "\n")
        #  日志无上限会吃内存(几百页的书上万行), 超了砍掉前面
        if int(self.text.index("end-1c").split(".")[0]) > 6000:
            self.text.delete("1.0", "2000.0")
        if self.autoscroll.get():
            self.text.see("end")
        self.text.configure(state="disabled")

    def copy_log(self) -> None:
        self.root.clipboard_clear()
        self.root.clipboard_append(self.text.get("1.0", "end-1c"))
        self.set_status("日志已复制到剪贴板")

    def clear_log(self) -> None:
        self.text.configure(state="normal")
        self.text.delete("1.0", "end")
        self.text.configure(state="disabled")

    def on_close(self) -> None:
        if self.runner and self.runner.is_alive():
            if not messagebox.askyesno("还在处理", "正在识别。退出会中断这一批，继续？"):
                return
            self.runner.cancel()
            self.runner.join(3.0)
        try:
            self.persist()
        except Exception:                     # noqa: BLE001 存不下不该挡住退出
            pass
        self.root.destroy()


def make_root() -> tk.Tk:
    """优先建支持拖拽的 root; 装不上就普通 Tk —— 功能完全不依赖它。"""
    try:
        from tkinterdnd2 import TkinterDnD      # noqa: PLC0415
        return TkinterDnD.Tk()
    except Exception:                           # noqa: BLE001
        return tk.Tk()


def run() -> int:
    root = make_root()
    App(root)
    #  .app 双击起来默认不在最前 —— 先置顶一下再放开, 否则窗口躲在别的应用后面
    try:
        root.attributes("-topmost", True)
        root.after(400, lambda: root.attributes("-topmost", False))
        root.lift()
        root.focus_force()
    except tk.TclError:
        pass
    root.mainloop()
    return 0
