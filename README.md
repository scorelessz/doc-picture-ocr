# 文档 OCR · 中文扫描件 → 可搜索 PDF + Markdown

把中文扫描件 PDF 变成**可搜索、可复制、可编辑**的两份产物：原图一个像素不动、底下压一层隐形文字的
`<名>.searchable.pdf`，以及段落化的正文 `<名>.md`。**全部在本机推理，不联网、不上传任何一页。**

macOS 专用（用到系统自带的 Vision 识别器）。双引擎交叉验证 + 规则自动裁决，没有人工校对环节。
实测一本 373 页的真书 **8.4 分钟**跑完，逐行取回率 **1.0000**，人工逐字核对 1100 字 **0 个汉字错**。

<!-- 截图占位：主界面 -->
![主界面](docs/images/screenshot-main.png)

<!-- 截图占位：处理中 / 质量报告 -->
![处理中](docs/images/screenshot-running.png)

---

## 快速开始

三条路，用哪条都行：

| | 怎么用 | 适合 |
|---|---|---|
| **① 图形界面（.app）** | 双击打包好的 `.app`，拖 PDF 进去，点开始 | 日常。自依赖，拷到别的 Mac 也能跑，不需要装 Python |
| **② 一键脚本** | 把 PDF 放进 `input/`，Finder 里双击 `一键OCR.command` | 已经 clone 了项目、配好 `.venv` |
| **③ 命令行** | `./books.sh`（见下） | 要调参数、要批处理、要接别的流程 |

```bash
./books.sh                       # 处理 input/ 下所有 PDF
./books.sh --force               # 重做（默认：产物已存在就跳过）
./books.sh --resume              # 续跑：复用已有中间产物，只补缺的那一步
./books.sh --input DIR --outdir DIR --dpi 300 --jobs 4
./books.sh --help                # 全部参数
```

产物（以 PDF 文件名为前缀）：

```
output/<名>.md               段落化正文 Markdown
output/<名>.searchable.pdf   原图 + 隐形文字层
work/<名>.report.md          质量报告  ← 没有人工校对环节，这是唯一的质量抓手
```

**每次跑完至少扫一眼质量报告的「优先复核的页」。** 流水线会诚实地报告自己哪里没把握
（分歧行、单源行、低置信行、双栏页、竖排页），这比默认它全对有用得多。

---

## 原理

```
扫描件 PDF
   │
   ├─ 渲染 ────── 300dpi 起；内嵌图原生分辨率更高就用原生（上限 600dpi / 8000 万像素）
   │              已有原生文字层的页直接取字，不重复识别
   │
   ├─ 双引擎并行识别
   │     ├─ macOS Vision        系统自带，快，对版面和断行友好
   │     └─ RapidOCR(PP-OCRv6)  本地 ONNX 小模型，中文印刷体更准，给连续置信度
   │
   ├─ 规则自动裁决 ── 两边读法不一致时逐行打分选一个，败者留在 alt 字段
   │
   ├─ 版面重建 ──── 去书眉页码 → 跨页合并段落 → 识别章节标题 → Markdown
   │
   └─ 隐形文字层 ── render_mode=3 把文字按原位写回原 PDF，原图不重编码
```

### 为什么非要两个引擎

一个引擎读错的时候，它自己不知道。两个引擎读错的地方**不重合**，于是「两边不一致」就成了一个
免费的错误定位信号 —— 哪怕裁决偶尔挑错，至少知道该去看哪一行。

同一份做旧扫描件、同一批页图，三种跑法：

| | 字符准确率 | 编辑距离 |
|---|---|---|
| 只 Vision | 0.9709 | 13 |
| 只 RapidOCR | 0.9978 | 1 |
| **双引擎融合** | **1.0000** | **0** |

融合**没有输给更强的那一方**，并且把它剩下的最后 1 个错也修掉了。

裁决规则（`src/book_fuse.py`，全部是确定性规则，不调模型）：

1. 两边归一化后相等 → 直接采用。
2. 不等 → 打分：**截断一票否决**（是另一方的前缀且显著更短，−5.0）、语言学异常数
   （中文里夹半角标点这类）、RapidOCR 置信度、中文字符占比。败者进 `alt` 字段，整行标 `divergent`。
3. **单源行必须收录**（铁律）—— 只有一个引擎出了结果的行，宁可留着也不丢。
   丢弃一律计入统计，不静默吞掉。
4. 行首只差一个字时：差的那个字是汉字/数字/字母就取长的（OCR 在页边吃掉首字，
   比凭空造一个汉字常见得多），是标点噪点才取短的。这条是为了保住章节号。

真书上分歧率 24~28%，但**分歧率高不等于成品错得多**：逐条看过的 14 条分歧里，
几乎全是 Vision 吞掉一个「的」，外加少量形近误读（荼毒→茶毒、凋零→调零），裁决 14/14 都挑对了。

---

## 实测数据

**373 页真书整本实跑**（595×1006pt，内嵌图 1392×2352 = 168dpi）：

| 指标 | 结果 |
|---|---|
| 总耗时 | **503.7s = 1.35s/页**（约 8.4 分钟） |
| 逐行取回率（隐形文字层） | **1.0000**（200200 字全部能在自己的位置上搜到） |
| 人工逐字核对 | 两页约 1100 字，**0 个汉字错**（只有 1 处全角「？」采成半角） |
| 版面 | 10098 行 → 2937 段 + 36 个标题；页标记 373/373 无缺页 |
| 去干净的噪声 | 页码 366 处、页缘碎块 3 处、重复 8 处 |
| 两引擎分歧率 / 单源率 | 25.0% / 0.2% |
| 体积 | 45.36 MB → 47.55 MB；Markdown 606 KB |
| 失败页 / 空页 | 0 / 0 |

**隐形文字层的体积开销与页数无关**（字体子集化后固定 +31 KB）。逐页比对 `extract_image`
的字节 md5 与源文件完全一致 —— **原图没有被重新编码**，可搜索 PDF 的画质等于原件。

其他规模：

| 素材 | 页 | 准确率 | 耗时 |
|---|---|---|---|
| 合成书（干净 A5@300dpi，含书眉/页码/两级标题/跨页段落/旋转页） | 5 | 字符 **1.0000** | 3.2s |
| 同一本做旧（150dpi + 噪点 + 书脊阴影 + JPEG q38） | 5 | 字符 **1.0000** | 4.2s |
| 真实手机拍摄件（每页约 80MP） | 3 | 取回 **1.0000** | 8.6s |

内存峰值 2.5~3.3 GB（几乎全部来自 RapidOCR/ONNX 的内部缓冲），16 GB 的机器跑几百页没问题。
磁盘峰值不随总页数涨（按 24 页一批渲染，识别完即删页图）。

---

## 已知局限

写在前面，省得你踩：

- **竖排和表格不支持。** 竖排页会在 Markdown 里留一条 WARNING 注释并原样输出。
  双栏会检测中缝、切成左右两栏分别成段，但仍然留 WARNING 要求复核。
- **分辨率决定上限，后处理救不回来。** 真正起作用的不是 dpi 这个数字，而是
  **每个汉字摊到多少像素**。上面那本 168dpi 的书每行 24 字、单字约 19pt，折回原生分辨率是
  每字约 **44×44 px**，很舒服。CJK OCR 的经验下限是每字约 **20px**（再低笔画开始粘连，
  「未/末」「日/曰」系统性出错），舒适区 **30px 以上**。
  同样是 168dpi 去扫 9~10pt 的常规开本，每字只剩 21~23px —— 正好踩线，那种件必须提高扫描分辨率。
  反过来，把 168dpi 的页渲到 300dpi 是**纯上采样**，不增加任何信息（实测 `--max-dpi 170`
  与默认 300dpi 的成品相似度 0.9957，正文一字不差）。
- **带劣质文字层的扫描件会被整页跳过。** 判据只看字符数（默认 ≥50），不评估质量。
  遇到「别处 OCR 过但结果很烂」的 PDF，加 `--force-ocr` 强制重认。
- **磁盘要留空间。** 400 页 A4 的页图约 0.5~1 GB，跑完才清（`--keep-pages` 可保留）。
- **拼贴式扫描取不到原生 dpi**（一页由多张小图拼成），退回 300 dpi。
- **术语表默认不启用。** `config/glossary.txt` 是按一部剧本整理的，套到别的书上会帮倒忙
  （实测把本来读对的人名硬改成剧本里的近形词，md 和隐形文字层会同时被污染）。
  要用得显式 `--glossary PATH`，
  建议另起一份而不是直接套这个。
- 旋转只实测了 90°/270°；180° 走同一条代码路径但没单独验证。
- `--dpi` 是**下限不是上限**：内嵌图分辨率更高的页会自动提升。要严格按它跑，加 `--no-native-dpi`。

更细的坑（旋转页坐标、CropBox 平移、书眉与章标题同形、自校验指标的失效模式）都记在
[BOOKS.md](BOOKS.md) 里，改代码前值得先读。

---

## 构建

### 依赖

- **macOS**（Vision 识别器是系统的）+ Xcode 命令行工具（`swiftc`）
- **Python 3.13**（paddlepaddle 系没有 3.14 的 wheel；项目只用 ONNX，但 venv 仍固定 3.13）
- **Tk**：`brew install python-tk@3.13` —— 图形界面要用，不装只能跑命令行

```bash
# 1. 虚拟环境
python3.13 -m venv .venv
.venv/bin/pip install -r requirements.txt     # pymupdf rapidocr onnxruntime opencv-python 等

# 2. 编译 Vision 识别器（仓库里带了编好的 bin/vision-ocr，换架构或改了 swift 才需要重编）
swiftc -O src/vision_ocr.swift -o bin/vision-ocr

# 3. 自检
./books.sh --help
```

主要依赖版本（`.venv` 实测）：`pymupdf 1.28.2`、`rapidocr 3.9.2`（自带 PP-OCRv6 small ONNX 模型，
不需要 PaddlePaddle）、`onnxruntime 1.30.0`、`opencv-python 5.0.0.93`、`numpy 2.5.3`、`pillow 12.3.0`。

### 打包成自依赖的 .app

```bash
.venv/bin/pyinstaller <打包配置>.spec --noconfirm       # 产物在 dist/
```

打包时有三样东西必须原样拷进包里并**保持相对路径**（`app/paths.py` 按这个布局找资源）：

- `src/` —— 作为**数据目录**拷贝，不要冻结成模块
  （`book_render.py` 里 `ROOT = Path(__file__).parent.parent`，冻结后指不到真实磁盘路径，
  `bin/vision-ocr` 就找不着了）
- `bin/vision-ocr` —— **必须保留可执行位**
- `config/` —— 可选，术语表默认不启用

模型权重随 `rapidocr` 包一起被打进去（约 10 MB），所以 .app 不需要联网下载任何东西。
成品体积主要来自 opencv / onnxruntime / pymupdf / numpy 这几个大件。
调试资源定位问题可以用环境变量 `OCR_RESOURCE_ROOT` 指定资源根目录。

### 发布新版本

```bash
packaging/release.sh 1.1.0                  # 构建 → 签名 → 压缩 → 发 GitHub Release
packaging/release.sh 1.1.0 --draft          # 先发草稿，确认无误再 publish
packaging/release.sh 1.0.0 --skip-build     # 不重建，直接发布 dist/ 里现成的 .app
```

脚本会先把「会失败的事」查完再动手：`gh` 有没有登录、工作区有没有未提交的改动、
tag 是不是已经存在。压缩用 `ditto -c -k --sequesterRsrc --keepParent` —— **不能用 `zip -r`**，
它会破坏 `.app` 里 Framework 的符号链接，解压出来的包打不开。

**`--skip-build` 存在的理由**：这个 app 只有 ad-hoc 签名，macOS 的 Gatekeeper 放行是
**按二进制**记住的。重新构建会产生新的二进制，之前的放行就失效了，要重新放行一次。
所以手上这个包如果已经验证过、放行过，发版时就别重建它。

**为什么不用 GitHub Actions 自动构建**：

1. macOS runner 在私有仓库里按 **10 倍**速率扣分钟数，一次构建（brew 装 Tk + PyInstaller
   + 上传 126MB）十几分钟，等于一个月跑十几次就把免费额度用光。
2. CI 产出的包同样没有 Apple 开发者签名，而且从网上下载会被打上 quarantine 属性，
   Gatekeeper 拦得**更凶**（会报「已损坏」而不是「来自身份不明的开发者」）。
   本机构建的包反而没有这个问题。
3. 成品只在自己的 Mac 上跑。为单机产物养一条 CI，收益抵不过维护成本。

真要上 CI，合理的分工是：**Actions 只跑测试和 lint，构建与发布留在本机**。

---

## 隐私

- **全部本地推理。** Vision 是系统框架，RapidOCR 是本地 ONNX 模型，嵌字是本地 PyMuPDF。
  整条流水线没有任何一步把你的文档发到网上。
- **唯一需要联网的时刻是第一次装依赖**（pip 下载包，模型权重也在包里）。装完拔网线照跑。
- **`input/` `output/` `work/` 三个目录在仓库里永远是空的**，`.gitignore` 把它们连同
  任何位置的 `*.pdf` / `*.md` / 扫描图片 / 逐行数据 JSON 一并挡在仓库外。
  新增项目文档需要在 `.gitignore` 的白名单里显式放行 —— 这是刻意的取舍：
  宁可漏掉一份项目文档（一眼就发现），也不要漏进一页你的书。

---

## 仓库结构

```
app/            图形界面（Tkinter）与资源定位
src/book_*.py   书籍线：渲染 / 双引擎 / 融合裁决 / Markdown / 隐形文字层
src/run_books.py          批处理驱动 + 质量报告
books.sh  一键OCR.command 书籍线入口
bin/vision-ocr  Swift 编的 macOS Vision 识别器
config/         术语表
docs/           截图等
BOOKS.md        书籍线权威文档：数据契约、裁决规则、踩过的坑、逐条实测
CLAUDE.md       项目级约定与不变量（改代码前必读）
```

正在重构为 Mac 原生（Swift）+ 多模型 + 本地/在线双模式，见 [docs/REFACTOR_PLAN.md](docs/REFACTOR_PLAN.md)。

---

## 许可

本项目自身代码采用 **[PolyForm Noncommercial License 1.0.0](LICENSE)**：允许非商业用途的使用、修改与分发（个人、学习研究、非营利组织等），**禁止商业使用**。作者本人仅用于内部与个人用途，不盈利。

第三方组件与模型各按其自身许可证，清单见 [docs/THIRD_PARTY_LICENSES.md](docs/THIRD_PARTY_LICENSES.md)；PolyForm 只覆盖本项目自己写的代码，不改变第三方组件的许可。

**如果以后要把打包好的 .app 公开分发，先看一眼这个**：PyMuPDF 是
**AGPL-3.0 或 Artifex 商业许可**双授权 —— 公开分发含它的二进制，就要按 AGPL 开放整个应用的源码，
或者买商业许可。自用和私有仓库不触发这条。其余依赖较宽松：
RapidOCR / opencv-python Apache-2.0，onnxruntime / pyclipper / Pillow MIT 系，
numpy / shapely BSD，PyInstaller GPLv2 但有明确的「允许打包并分发非自由程序」例外。

## Mac App

### 从 zip 安装

`packaging/build_app.sh` 生成 `dist/DocOCR-版本-构建号.zip`。解压后把 `DocOCR.app` 拖进「应用程序」或 `~/Applications`，需要 Apple Silicon 和 macOS 14 以上。

这个 App 只有本机签名（ad-hoc），没有公证。**拷到别的 Mac 后**系统会拦下，用下面任一方法打开：

- 右键点图标 → 打开，在弹窗里再点一次「打开」。新版 macOS 如果没有这个选项，到「系统设置 → 隐私与安全性」点「仍要打开」。
- 或在终端运行：`xattr -dr com.apple.quarantine /Applications/DocOCR.app`

几点说明：

- 识别模型已经在 App 里。高精度模式的模型在设置里按需下载，约 1.1 GB。
- 每个新版本第一次访问「桌面」「文稿」时，系统都会询问一次，这是正常的。用文件选择窗或拖入的文件不会问，但默认输出目录在「文稿」下。
- 换版本后，之前保存的 API Key 需要在设置里授权一次或重新填写。

### 从源码运行

需要 macOS 14+、Xcode 和 Metal Toolchain（`xcodebuild -downloadComponent MetalToolchain`）。还没有签名和打包，先在本机运行：

```bash
swift build -c release
.build/release/DocOCRApp
```

首次打开选「仅本地使用」或「允许联网」，然后在设置 → 模型下载识别模型。默认不联网，用户文件不离开这台 Mac。
冒烟测试：`./dev/p7_smoke.sh 英文书.pdf 中文书.pdf`。详情见 `docs/P7_RESULTS.md`。
