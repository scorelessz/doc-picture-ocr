# 重构 Workflow：Mac 原生 · 书籍扫描件 · 多模型 · 本地/在线双模式

状态：**第二版，决策已确认**（2026-10-30）。本文件只定流程，还没有改任何代码。

## 0. 需求

| # | 需求 | 落地方式 |
|---|---|---|
| 1 | 支持 Xiaomi-OCR-0 | 0.8B，基于 Qwen3.5-0.8B-Base，Apache-2.0。官方 Transformers / vLLM / SGLang；社区 GGUF（llama.cpp，需 mmproj）与 Ollama 包；**未见 MLX 版**。输出 Markdown / OTSL / LaTeX，**不输出坐标** |
| 2 | 支持 MiniCPM | MiniCPM-V 4.7（2026-10-12，1B 与 35B-A3B，Apache-2.0）。默认 1B；35B-A3B 按内存可选 |
| 3 | Mac 原生构建 | Swift + SwiftUI + SwiftPM，取代 Python + Tk + PyInstaller。App 与 CLI 共用一个核心库 |
| 4 | **ANE 加速** | 能上 ANE 就上，否则 Metal GPU，最后 CPU；启动时探测，可手动覆盖，实际用到的硬件写进报告 |
| 5 | 支持 Paddle 模型 | PP-OCRv6（det/cls/rec）、PP-DocLayoutV3：paddle2onnx → Core ML（ANE）/ ONNX Runtime 兜底 |
| 5a | **支持 PaddleOCR-VL-1.6** | 百度文档解析 VLM。官方 Apple Silicon 路径是 mlx-vlm（≥0.3.11）服务 |
| 5b | **支持 MinerU2.5-Pro** | opendatalab，1.2B（2605 版），官方 vLLM + `mineru-vl-utils`；社区 MLX 4/8bit 版。两阶段：先版面检测（**带框**）、再逐块识别；社区 MLX 卡注明版面阶段要缩到 1036×1036 |
| 5c | **支持 OvisOCR2** | 0.8B，基于 Qwen3.5-0.8B 后训练，整页 → Markdown（阅读顺序），官方 vLLM / Docker；HF `ATH-MaaS/OvisOCR2`（需核实是否官方） |
| 6 | 本地模型或在线 API | 统一 `Provider` 抽象；在线服务预置几家 + 自定义，见 §3 |
| 7 | **输出 Markdown 可选** | 产物可勾选：可搜索 PDF / Markdown（至少选一个） |
| 8 | **选 Markdown 时识别分页、去页眉页脚页码** | 见 §4 |
| — | 剧本线 | **删除**。只支持书籍扫描件 |
| — | **Mac 适配门槛** | 只收能用 MLX 或 llama.cpp（Metal）在本机跑通的模型；只能靠 vLLM/CUDA 或 transformers+MPS 的不加入（Phase 1 判定） |

## 1. 决策（已定）

| ID | 决策 |
|---|---|
| D1 | 全 Swift 重写；Python 只留在开发期工具（模型转换、基准评测） |
| D2 | 在线 provider 默认关；**每次要上传都弹窗由用户明确确认**（§3.2）；本地失败绝不自动切在线 |
| D3 | VLM 运行时：进程内 llama.cpp（Metal）为主 + OpenAI 兼容 HTTP 兜底；MLX 等 Phase 1 实测后再定 |
| D4 | 剧本线删除，只做书籍线 |
| D5 | macOS 14+，仅 Apple Silicon |

## 2. 架构判断

### 2.1 VLM 不给坐标 →「几何骨架 + 读字引擎」

可搜索 PDF 要把字写回原位、去页眉页脚靠页缘位置、跨页合并靠行位置 —— 全都需要**行框**。

- **几何引擎**（框 + 字 + 置信度）：Vision、PP-OCRv6。
- **读字引擎**（只出字）：Xiaomi-OCR-0、MiniCPM-V、PaddleOCR-VL-1.6、MinerU2.5-Pro、OvisOCR2。
  例外：MinerU2.5-Pro 的版面阶段输出块级框，可直接作区域模式的切块来源（与 PP-DocLayoutV3 并列）。
  - **区域模式（默认）**：按行框或 PP-DocLayoutV3 版面块裁图逐块读，结果天然带坐标。
  - **整页模式**：整页出 Markdown，再与几何引擎的行做序列对齐挂回坐标；对不上的标 `unaligned`，不静默丢弃。

### 2.2 VLM 会「润色」→ 默认组合必须含一个 CTC 型识别器

VLM 有语言模型先验，会补字、改通顺、吞重复，这类错**读起来是对的**。CTC 识别器（Vision / PP-OCRv6 rec）
不编造字，与 VLM 的错误相关性低，正是交叉验证需要的。VLM 单引擎模式可选，但报告标「无交叉验证」。

### 2.3 加速：各运行时实际用到的硬件

| 运行时 | 硬件 | 用在哪 |
|---|---|---|
| Vision 框架 | 系统自动调度 ANE / GPU | Vision 引擎 |
| Core ML（`.cpuAndNeuralEngine` / `.all`） | **ANE** / GPU / CPU | PP-OCRv6、PP-DocLayoutV3 |
| ONNX Runtime + CoreML EP | ANE/GPU，不支持的算子回落 CPU | Paddle 模型转 Core ML 失败时兜底 |
| llama.cpp（Metal） | GPU | 三个 VLM（GGUF） |
| MLX（可选） | GPU，**不用 ANE** | VLM |

ANE 现实中只适合小的卷积/CTC 模型；0.8B~1B 的 VLM 在 Mac 上跑在 Metal GPU。

## 3. Provider 层

### 3.1 来源

| 类型 | 内容 |
|---|---|
| 本地·进程内 | Vision、Core ML、ORT、llama.cpp |
| 本地·服务 | Ollama、LM Studio、llama-server、mlx-vlm（都是 OpenAI 兼容，填 `http://localhost:…`） |
| 在线·预置 | OpenAI、Google Gemini（OpenAI 兼容端点）、阿里云百炼 DashScope（兼容模式）、硅基流动 SiliconFlow、OpenRouter、Anthropic |
| 在线·自定义 | 任意 OpenAI 兼容服务：填 Base URL + Key + 模型名 |

**自适应**：用户选预置或填自定义后点「测试连接」——
1. 拉 `/models` 列表供选择（拉不到就允许手填）；
2. 用一张**程序自己生成的合成测试图**探测：是否支持图片输入、图片尺寸上限、返回格式。**不使用用户的任何文件**；
3. 探测结果存成该 provider 的能力档案，后续自动按档案裁图/缩放/选提示词模板。

Key 只存 Keychain，不写进设置文件和日志。

### 3.2 上传确认（D2）

只要本次任务会把页面图片发到**非本机**地址，开始前必弹确认窗，内容：

- 服务商名称 + 实际域名（例：`api.siliconflow.cn`）
- 将上传的文件名、页数、图片总大小；按能力档案估算的请求数与费用（估不出就写「未知」）
- 一个必须手动勾选的复选框：「我确认将以上 N 页图片上传到 <域名>」，勾选前「开始」按钮不可点
- 选项：「仅本次」（默认）/「本批次内不再询问」。**没有「永久不再询问」**

不确认 → 任务不开始（不是降级成本地跑一半）。每次上传记录写进质量报告（时间、域名、页码）。
测试：未确认时在线 provider 发不出任何请求（单测断言网络层零调用）。

### 3.3 可选功能：在线裁决（DeepSeek / 通义千问）

本地引擎读法不一致的地方，用户可以选择交给线上模型裁决。**默认关**，开启处明确写着「数据会被上传」。

| 裁决方式 | 上传什么 | 适合 |
|---|---|---|
| 看图裁决（通义千问视觉模型等） | 分歧行的**裁切图** + 各引擎候选文字 | 形近字、漏字、标点：要看图才能判 |
| 纯文本裁决（DeepSeek 等） | 分歧行的候选文字 + 上下文前后各一行，**不传图片** | 语言上明显不通的读法；判不了形近字，结果标「仅文本依据」 |

- 只传**分歧行**，不传整页、不传整本。确认窗写清：将上传 N 处分歧（约 M 字 / K 张裁切图）、服务商与域名、预估费用。
  走 §3.2 同一个确认闸门：不勾选不发送，本地失败不自动转在线。
- 裁决结果只在候选之间**选一个**，不允许写入候选里没有的字（防止线上模型自己「润色」出新错）；
  选不出就保留本地裁决并标记。每条裁决的来源（本地/哪家模型）、上传记录逐条写进质量报告。
- Phase 1 实测：通义千问看图裁决 231 处分歧，与文字层交叉核对可信；DeepSeek flash 适合做纯文本归类，不看图。

## 4. 输出与 Markdown 分页处理

产物（可勾选，至少一个）：

```
<名>.searchable.pdf   原图不重编码 + 隐形文字层（PDFKit / CoreGraphics，取代 pymupdf）
<名>.md               段落化正文（可选）
<名>.report.md        质量报告（总是生成）
```

勾选 Markdown 时的处理（移植并强化现有 `book_md.py`）：

1. **页眉页脚检测**：只在页缘区（上/下各约 8% 页高）的短文本里找；跨页重复 → 精确匹配后再模糊兜底
   （OCR 对页眉本身也逐页读得不同）；奇偶页分别统计（书籍左右页页眉常不同）。
2. **页码检测**：页缘区的阿拉伯数字 / 罗马数字 / 中文数字 / `- 12 -`、`第 12 页` 等格式；
   要求与相邻页**序列一致**（递增、允许跳页），孤立数字不当页码，防止误删正文里的数字。
3. **跨页合并段落**：上一页末行没有句末标点、下一页首行没有段首缩进 → 合并；章节标题不参与合并。
4. **分页标记**（选项）：无 / `<!-- p.12 -->` 注释（默认，渲染时不可见但可回溯原页）/ 可见分隔线。
5. **删除必须可审计**：去掉的每一处页眉、页脚、页码都按页列进质量报告，数量写进摘要；不静默吞。

可搜索 PDF 不受上述删除影响 —— 页眉页码仍留在隐形文字层里（它们本来就印在页面上）。

## 5. 目标架构（精简后）

```
Package.swift
├── OCRCore        纯 Swift，无 Apple 框架依赖（Linux 上可跑单测）
│   ├── Model        Page / Line / BBox / Reading，JSON 契约与现有 *.vision.json 兼容
│   ├── Normalize    全半角、省略号折叠（NFKC 之后）
│   ├── Fuse         N 引擎几何配对 + 裁决（book_fuse / crosscheck.match_lines / postcheck 移植）
│   ├── Align        整页 VLM 文本 ↔ 行框对齐
│   └── BookLayout   页眉页脚页码、跨页合并、标题、分页标记 → Markdown
├── OCREngines     VisionEngine / PaddleEngine / LayoutEngine / VLMReader
├── OCRRuntime     CoreML / ORT / LlamaCpp / MLX(可选) / HTTP
├── OCRProviders   预置 + 自定义、能力探测、Keychain、上传确认闸门
├── ModelStore     HF / ModelScope 下载、sha256 校验、~/Library/Application Support
├── PDFOut         隐形文字层
├── ocr-cli        命令行（开关对齐现有 books.sh）
└── DocOCRApp      SwiftUI
```

相比上一版删掉：剧本版面、人工校对界面、术语表回填、拼接校验。

### 5.0 已定决策（2026-10-31）

- 默认组合：PP-OCRv6（Core ML，几何 + CTC 核对）+ PaddleOCR-VL-1.6（整页读字），Vision 降为可选。
- 模型分发（2026-11-01 更新）：默认不打包，App 内下载或从文件导入，仓库公开。PP-OCRv6 来自本仓库 Release models-v1，VL 来自 Hugging Face 钉死版本，都校验 sha256。
- 页面尺寸：扫描件尺寸不可控，**任意尺寸都必须正常识别**（一致率 ≥98%），预设尺寸只是加速手段，可回落 GPU/CPU。
- 倒扫页：整页方向判定，不做逐行方向分类（逐行分类实测把正常长行判成 180°，读成乱码）。
- 旧 Python 链路与 `src/rapid_pages.py`：保留，用户通知后再删。
- 测试期内存峰值偏高可接受（后续主用设备 M6 / 32 GB）。

- 签名：本机签名（ad-hoc），不做公证；用户没有 Apple 开发者账号（2026-11-01）。

### 5.1 诊断日志（用户 2026-10-31 要求：要在其他 Mac 上测试）

所有入口（`ocr-cli` 各子命令、之后的 App）都要能打开详细日志，方便在别的机器上排查：

- 开关：`--log-level error|warn|info|debug|trace`（默认 info），`--log-file <路径>`；
  环境变量 `DOCOCR_LOG=debug` 等价，便于不改命令行就打开。App 里放在设置的「诊断」一栏。
- 内容：
  - 开头一段环境信息：macOS 版本、芯片、内存、可用磁盘、程序版本与 git commit、Vision 修订版、
    各模型文件名 + sha256 前 12 位、Core ML 计算单元的**请求值与实际落点**（ANE / GPU / CPU）、运行参数；
  - 每页：dpi、页图尺寸、暗像素比、白页闸门结论、各引擎行数与耗时、融合统计、去重条数、页码/页眉删除；
  - 每个阶段的耗时与内存峰值；所有警告和错误带页号与上下文（异常类型、调用阶段）。
- 隐私：日志默认**不写识别出的正文**，只写数字和结构；要带原文须显式 `--log-text`。
  日志只落本地文件，不自动上传。
- 格式：每行一条 JSON（便于机器汇总），另可 `--log-format text` 给人读。
- 配套 `ocr-cli doctor`：只做环境自检（框架、模型文件、计算单元、写权限），不处理任何书，
  用于新机器上先确认环境。

## 6. 分阶段 Workflow（每阶段有过关门槛）

### Phase 0 · 清理 + 冻结基准
- **删除剧本线**（git 历史保留）：`run.sh`、`src/{run_vision,run_rapidocr,to_markdown,make_review,check_fixes,contactsheet,combine,audit,arbitrate,nearmiss,run_tesseract}.py`；`crosscheck.py` 只保留书籍线用到的 `match_lines`；`CLAUDE.md` 改写为书籍线版本。
- 金标准集：真书 373 页抽样 + 合成做旧样本 + 各类页眉页码样式的页。
- 现行 Python 书籍线跑一遍记基准：字符准确率、编辑距离、逐行取回率、分歧/单源率、页眉页码去除的查全/查准、秒/页、峰值内存。
- **门槛**：`bench/baseline.json` 入库。

### Phase 1 · 模型实测（Mac 上跑脚本，不写产品代码）
- 矩阵：{Xiaomi-OCR-0, MiniCPM-V 4.7 1B, PaddleOCR-VL-1.6, MinerU2.5-Pro 1.2B, OvisOCR2, PP-OCRv6, Vision} × {llama.cpp, MLX, Transformers-MPS, Core ML, ORT-CoreML} × {区域, 整页}。
- 指标：CER、**编造率**、**吞字率**、秒/页、峰值内存、实际落在 ANE/GPU/CPU。
- 脚本只输出**数字**（JSON），不输出识别文本，方便你直接把结果提交回仓库给我看而不外传书的内容。
- **门槛**：决策表 → 默认引擎组合、默认运行时、D3 终版。

### Phase 2 · Swift 骨架 + Vision + CLI
- **门槛**：同一批页图，Swift 版输出与现有 `bin/vision-ocr` 逐行一致。

### Phase 3 · 移植融合与产出
- Fuse / BookLayout / PDFOut；§4 的分页处理在这里实现。
- **门槛**：喂相同 JSON，md 与 Python 版逐字一致（或差异全部可解释）；PDF 逐行取回率 1.0000、原图 md5 不变；页眉页码去除不低于基准。

### Phase 4 · Paddle 引擎
- `tools/convert_paddle.py`：paddle2onnx → coremltools → `.mlpackage` + sha256 清单（也用于导入自训 Paddle 模型）。
- **门槛**：精度与 RapidOCR 持平；记录 ANE 命中。此后 Python 运行时依赖全部去掉。

### Phase 5 · VLM 读字引擎（本地）
- llama.cpp 运行时 + 三个模型的提示词模板 + 区域/整页模式 + 对齐；融合扩到 N 引擎。
- **门槛**：默认组合 ≥ 基准，编造率有独立指标。

### Phase 6 · Provider 层
- 含 §3.3 可选在线裁决（DeepSeek / 通义千问）。
- §3 全部内容。**门槛**：断网时本地功能全可用；未确认时零外发请求。

### Phase 7 · SwiftUI App
- 批处理、进度、产物勾选、分页选项、质量报告、模型管理、Provider 设置与测试连接、加速探测面板。
- **门槛**：对齐现有 `.app` 全部功能；Python 实现下线。

### Phase 8 · 打包发布
- Xcode archive → 签名 → 公证 → 沿用 `packaging/release.sh`；模型首次启动按需下载，不进 .app。

## 7. 怎么拿到你的 Mac 上测试

本会话在 Linux 云容器里，没有 Xcode，读不到你的 Mac。三条路，按快捷程度排：

**A. Remote Control（最快：我直接在你的 Mac 上编译、跑测试、读结果）**
你的 `Mac-mini-zwq` 已开 Remote Control，但现有文件夹（openwrt / work / Ignore）都**不对云会话开放**。要做的：
1. 更新 Mac 上的 Claude 桌面 App；
2. 在 设置 → Claude Code → Remote Control 里加入本项目所在文件夹（不能在 `~` 下的隐藏目录或 `~/Library` 里）；
3. 告诉我，我发起连接请求，你在 Mac 上点允许。

注意：这条路下我读到的文件内容会进入这个云端对话。只跑基准数字没问题；若要我看识别出的正文，用合成样本或你不介意的页。

**B. git pull + 一条命令（不依赖 Remote Control）**
每个阶段我会提供一个入口脚本，你只需：
```bash
git fetch origin claude/zen-dijkstra-81hcfw && git checkout claude/zen-dijkstra-81hcfw && git pull
./dev/check.sh p1        # 或 p2 …：装依赖 → 构建 → 测试 → 基准，结果写到 bench/results/
```
- P1 是脚本（llama.cpp 用 brew 装，Python 依赖用 uv 装进隔离环境），不需要编译。
- P2 起是 `swift build -c release`，只需 Xcode Command Line Tools；本机构建不带 quarantine 属性，不会被 Gatekeeper 拦。
- 跑完 `git add bench/results && git commit && git push`（只有数字），我拉下来分析。

**C. GitHub Actions 只跑测试**
沿用 README 的结论：macOS runner 按 10 倍扣分钟、CI 产物下载后被 quarantine 拦得更凶。所以 Actions 只跑
`OCRCore` 的单测（可以用 Linux runner，不扣 10 倍），构建和实测留在本机。

## 参考

- Xiaomi-OCR-0：<https://huggingface.co/xiaomi-research/Xiaomi-OCR-0>，技术报告 <https://arxiv.org/abs/2609.36136>，社区 GGUF <https://github.com/xzl01/Xiaomi-OCR-0-GGUF/releases/tag/v1.0.0>
- MiniCPM-V：<https://github.com/openbmb/MiniCPM-V>
- PaddleOCR-VL on Apple Silicon：<https://www.paddleocr.ai/latest/version3.x/pipeline_usage/PaddleOCR-VL-Apple-Silicon.html>
- MinerU2.5-Pro：<https://huggingface.co/opendatalab/MinerU2.5-Pro-2605-1.2B>
- OvisOCR2：<https://huggingface.co/ATH-MaaS/OvisOCR2>
