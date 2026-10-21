# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller 配方：书籍线 GUI → 自依赖的 DocPictureOCR.app（onedir）。

用法一律通过 packaging/build.sh，不要手敲 pyinstaller。

设计要点（改之前先读）
----------------------
1. **src/ 作为「数据目录」拷贝，不冻结成模块。**
   book_render.py 里 `ROOT = Path(__file__).resolve().parent.parent`，一旦被冻结进
   PYZ，`__file__` 就指向归档内的假路径，`ROOT/"bin"/"vision-ocr"` 找不到任何东西。
   作为数据目录拷贝 + 运行时 `sys.path.insert(resource_path("src"))`（app/paths.py
   的 bootstrap()）则 ROOT 仍是真实磁盘路径，一切照旧。
   代价：PyInstaller 的静态分析**看不见** src/ 里的 import，所以书籍线用到的第三方
   包必须在下面 HIDDEN 里手工点名。漏一个 = 用户那边「双击没反应」。

2. **bin/vision-ocr 用 datas 而不是 binaries。**
   它是 Swift 编的独立可执行文件，不是 Python 扩展。走 binaries 的话 PyInstaller 会
   去改写它的 load commands 并重新签名；走 datas 则原样拷贝。可执行位由 build.sh 的
   chmod + app/paths.py 的 _ensure_executable() 双保险，ad-hoc 签名由 build.sh 补。

3. **rapidocr 的模型是 pip 包里的数据文件**（models/*.onnx 共 30MB + 两个 yaml）。
   不收进来的话第一次识别会去联网下载——这个项目承诺纯本地，必须打进包里。
"""

import os
import sys
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

ROOT = Path(SPECPATH).resolve().parent          # noqa: F821  (PyInstaller 注入)

APP_NAME = "DocPictureOCR"                      # .app 的文件名（保持 ASCII）
EXE_NAME = "OCR"                                # Contents/MacOS/OCR
DISPLAY_NAME = "文档图片 OCR"                    # Finder 里显示的名字
BUNDLE_ID = "com.local.docpictureocr"
VERSION = os.environ.get("OCR_APP_VERSION", "1.0.0")
ICON = ROOT / "packaging" / "AppIcon.icns"      # build.sh 负责生成；没有就不带图标


# ---------------------------------------------------------------- 数据文件

def tree(src: Path, dest: str, suffixes=None):
    """把一个目录按原结构收进来。跳过 __pycache__ / 点文件。"""
    out = []
    for p in sorted(src.rglob("*")):
        if not p.is_file():
            continue
        if "__pycache__" in p.parts or p.name.startswith("."):
            continue
        if suffixes and p.suffix not in suffixes:
            continue
        out.append((str(p), str(Path(dest) / p.relative_to(src).parent)))
    return out


datas = []

#  书籍线的代码，连同它 import 的三个剧本线纯工具模块
#  （book_md→normalize、book_fuse→crosscheck/normalize/postcheck、run_books→postcheck）
datas += tree(ROOT / "src", "src", suffixes={".py"})

#  Vision 识别器（Swift 二进制）。缺它 = 双引擎塌成单引擎，book_engines 直接报错。
_vision = ROOT / "bin" / "vision-ocr"
if not _vision.is_file():
    raise SystemExit(f"ERROR: 找不到 {_vision}；先 "
                     f"swiftc -O src/vision_ocr.swift -o bin/vision-ocr")
datas += [(str(_vision), "bin")]

#  术语表（书籍线默认不启用，但界面里可以选）
if (ROOT / "config").is_dir():
    datas += tree(ROOT / "config", "config")

#  rapidocr 的 ONNX 权重与 yaml 配置
datas += collect_data_files("rapidocr")


# ---------------------------------------------------------------- 隐式依赖

#  src/ 是数据目录，它的 import 对 PyInstaller 不可见 —— 全部手工点名。
HIDDEN = [
    "pymupdf",            # book_render / book_pdf：渲染 + 隐形文字层
    "fitz",               # pymupdf 的旧名，有些代码路径还在用
    "numpy",
    "cv2",                # rapidocr 的预处理
    "PIL", "PIL.Image",
    "shapely", "pyclipper",   # rapidocr 的 DB 后处理
    "onnxruntime",
    "omegaconf", "yaml",      # rapidocr 读 config.yaml / default_models.yaml
    "tqdm", "colorlog", "requests",
]
#  rapidocr 本体：子模块用 importlib 动态挑引擎，全收。
HIDDEN += collect_submodules("rapidocr")


# ---------------------------------------------------------------- 排除

EXCLUDES = [
    #  rapidocr 支持 6 种推理后端，我们只用 onnxruntime。其余的根本没装，
    #  列在这里是为了让构建日志干净、并防止有人日后 pip 进来后体积暴涨。
    "torch", "torchvision", "paddle", "paddlepaddle", "openvino", "tensorrt",
    "MNN", "mnn",
    "rapidocr.inference_engine.paddle",
    "rapidocr.inference_engine.pytorch",
    "rapidocr.inference_engine.openvino",
    "rapidocr.inference_engine.tensorrt",
    "rapidocr.inference_engine.mnn",
    #  onnxruntime 的训练/量化/转换工具链，推理一行都用不到
    "onnxruntime.transformers", "onnxruntime.quantization",
    "onnxruntime.tools", "onnxruntime.training", "onnxruntime.backend",
    #  科学计算全家桶：没装，但 numpy/PIL 的可选分支会去试
    "matplotlib", "scipy", "pandas", "sympy", "numba",
    "IPython", "jupyter", "notebook", "pytest", "nose",
    #  打包器自己
    "PyInstaller", "altgraph", "macholib",
    #  可选拖拽支持：装了就自动生效，没装也不影响（app/gui.py 里是 try/except）
    "tkinterdnd2",
    #  tkinter 的两个重量级附件，界面没用到
    "tkinter.test", "test",
]


# ---------------------------------------------------------------- 组装

a = Analysis(                                   # noqa: F821
    [str(ROOT / "app" / "launcher.py")],
    pathex=[str(ROOT)],
    binaries=[],
    datas=datas,
    hiddenimports=HIDDEN,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=EXCLUDES,
    noarchive=False,
    optimize=0,
)

# ---------------------------------------------------------------- 瘦身

#  onnxruntime 的 pip wheel 里有两份同样的推理引擎:
#    capi/onnxruntime_pybind11_state.so   39 MB  ← Python 走的就是它
#    capi/libonnxruntime.1.30.0.dylib     31 MB  ← 给 C/C++ 调用方用的
#  `otool -L onnxruntime_pybind11_state.so` 里**没有**这个 dylib(引擎是静态链进去的),
#  包里也没有任何一处 dlopen 它。实测删掉后 env -i 下的 --selftest 照常跑通
#  (4 页 112 行、取回 1.0000)。省 31 MB。
#  ——如果哪天 onnxruntime 改成动态链接, 症状是 import onnxruntime 直接报
#  "Library not loaded"; 那就把下面这行删掉。
#  cv2 砍不动: cv2/.dylibs 里 99 个库共 79.7 MB(整个 ffmpeg 栈 + OpenEXR + avif),
#  看着和 OCR 毫无关系, 但 `cv2.abi3.so` 的 LC_LOAD_DYLIB 直接写着
#  libavcodec/libavformat/libswscale/libavutil/libavdevice/libOpenEXR*/libavif,
#  其余都在它们的传递依赖里 —— 按 otool 算过闭包: **99 个全部可达, 0 个可删**。
#  要真砍得换 wheel(opencv-python-headless 也带 ffmpeg, 得自己编 core+imgproc),
#  那是另一件事, 不在打包范围内。
_DROP = ("libonnxruntime.",)
a.binaries = [b for b in a.binaries
              if not any(k in b[0] for k in _DROP)]

pyz = PYZ(a.pure)                               # noqa: F821

exe = EXE(                                      # noqa: F821
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name=EXE_NAME,
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,                                  # UPX 在 macOS/arm64 上会弄坏签名
    console=False,                              # 窗口程序；从终端跑时 stdout 照常可见
    disable_windowed_traceback=False,
    argv_emulation=False,                       # 不装 AppKit 的 odoc 转 argv 钩子
    target_arch=None,                           # 跟随构建机（arm64）
    codesign_identity=None,                     # 统一由 build.sh 做 ad-hoc 签名
    entitlements_file=None,
)

coll = COLLECT(                                 # noqa: F821
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name=APP_NAME,
)

app = BUNDLE(                                   # noqa: F821
    coll,
    name=f"{APP_NAME}.app",
    icon=str(ICON) if ICON.is_file() else None,
    bundle_identifier=BUNDLE_ID,
    version=VERSION,
    info_plist={
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": DISPLAY_NAME,
        "CFBundleExecutable": EXE_NAME,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": VERSION,
        "CFBundleVersion": VERSION,
        "CFBundleDevelopmentRegion": "zh_CN",
        #  Retina：不写这条 macOS 会按 1x 位图拉伸整个 Tk 窗口，中文糊成一团
        "NSHighResolutionCapable": True,
        #  Tcl/Tk 9 + PyInstaller 6 的 arm64 bootloader 需要的底线
        "LSMinimumSystemVersion": "11.0",
        #  跟随系统深浅色（Tk 9 自己会处理）
        "NSRequiresAquaSystemAppearance": False,
        #  纯本地推理，不进 Dock 菜单栏之外的任何地方
        "LSApplicationCategoryType": "public.app-category.productivity",
        "NSHumanReadableCopyright": "本地运行，不上传任何文件。",
    },
)
