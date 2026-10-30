# 重构 Workflow：Mac 原生 · 多模型 · 本地/在线双模式

状态：**草案，待确认**（2026-10-30）。本文件只定流程和决策点，还没有改任何代码。

## 0. 需求 → 解读

| # | 需求 | 解读（带 ⚠ 的是假设，需确认） |
|---|---|---|
| 1 | 支持 xiaomi-ocr-0 | **Xiaomi-OCR-0**（2026-09-28 技术报告，arXiv 2609.36136）。0.8B，基于 Qwen3.5-0.8B-Base，Apache-2.0。官方给出 Transformers / vLLM / SGLang；社区有 GGUF（llama.cpp，需 mmproj）和 Ollama 包；**未见 MLX 版**。输出 Markdown / OTSL 表格 / LaTeX，**不输出坐标** |
| 2 | 支持 MiniCPM | **MiniCPM-V 4.7**（2026-10-12，1B 与 35B-A3B 两档，Apache-2.0），llama.cpp / Ollama 可用。默认接 1B；35B-A3B 只在内存够的机器上作可选项 |
| 3 | Mac 原生构建 | ⚠ 用 **Swift + SwiftUI + Xcode / SwiftPM** 重写，取代 Python + Tk + PyInstaller。App 与 CLI 共用同一个 Swift 核心库 |
| 4 | 「apn 加速」 | ⚠ 理解为 **ANE（Apple Neural Engine）**。原则：能上 ANE 就上，不能就 Metal GPU，最后 CPU；运行时自动探测、可手动覆盖 |
| 5 | 支持 Paddle 模型 | **PP-OCRv6**（det/cls/rec）、**PP-DocLayoutV3**（版面）、**PaddleOCR-VL-1.6**（VLM）。Mac 上不跑 PaddlePaddle 本体，走 paddle2onnx → ONNX →（Core ML 或 ONNX Runtime） |
| 6 | 本地模型或在线 API key | 统一抽象 `Provider`：本地进程内推理 / 本地服务（Ollama、LM Studio、llama-server、mlx-vlm）/ 在线 API（OpenAI 兼容协议 + 各家预设）。API key 存 **Keychain** |

## 1. 开工前必须定的决策

| ID | 问题 | 建议 | 理由 |
|---|---|---|---|
| D1 | 原生到什么程度 | **全 Swift 重写**，Python 只留在开发期工具（模型转换、基准评测） | 「原生构建」的价值在于：不带 Python 解释器、签名公证简单、能直接调 Vision/Core ML/PDFKit。顺带去掉 pymupdf 的 AGPL 依赖 |
| D2 | 在线 provider 与现有边界冲突 | **允许，但默认关，逐文件显式同意**；绝不从本地自动降级到在线 | 现行 `CLAUDE.md`「用户文件不得外传」是硬边界，要你明确授权才能改。改后边界变成「默认不外传；外传必须本次操作显式选择」 |
| D3 | VLM 推理运行时 | **进程内 llama.cpp（Metal）为主 + OpenAI 兼容 HTTP 兜底**；MLX Swift 作为 Phase 1 实测后的可选项 | 三个 VLM 都已有 GGUF；Xiaomi-OCR-0 没有 MLX 版、MLX Swift 对 Qwen3.5 视觉结构的支持未确认。HTTP 兜底同时覆盖本地服务和在线 API，一套代码 |
| D4 | 两条线是否都保留 | **都保留**：书籍线（全自动）+ 剧本线（人工校对） | 两条线共享引擎与融合层，只是版面重建和校对环节不同 |
| D5 | 最低系统 | **macOS 14+、仅 Apple Silicon** | MLX / ANE / 统一内存是加速的前提；Intel 机器跑 VLM 没有实用价值 |

## 2. 三个架构判断（决定了后面的分阶段方式）

### 2.1 VLM 不给坐标 → 「几何骨架 + 读字引擎」分层

现有流水线的核心不变量全部依赖**行级坐标**：交叉验证按几何对齐、校对结果按「页码 + 坐标」回填、
可搜索 PDF 要把字写回原位。Xiaomi-OCR-0 / MiniCPM-V 整页输出 Markdown，没有坐标。

所以拆成两类角色：

- **几何引擎**（出框 + 字 + 置信度）：Vision、PP-OCRv6。负责行框、阅读顺序、版面。
- **读字引擎**（只出字）：Xiaomi-OCR-0、MiniCPM-V、PaddleOCR-VL。两种喂法：
  - **区域模式（默认）**：按几何引擎的行框/块框（或 PP-DocLayoutV3 的版面块）裁图，逐块读字
    （Xiaomi-OCR-0 官方区域提示词就是 `Extract the text in the image.`），结果天然带坐标。
  - **整页模式**：整页出 Markdown，再与几何引擎的行做序列对齐挂回坐标；对不上的段落标 `unaligned`，不静默丢弃。

### 2.2 VLM 会「润色」→ 必须保留至少一个 CTC 型识别器做交叉验证

VLM 带语言模型先验，会把原文「改通顺」、补字、吞重复（剧本里的「返，返，返」正是这类）。
这种错**读起来是对的**，人工校对最难发现。CTC 识别器（PP-OCRv6 rec / Vision）不会编造字，
两类引擎的错误相关性低 —— 正好是双引擎交叉验证最需要的性质。

因此：**任何默认组合都必须包含一个 CTC 型引擎**；VLM 单引擎模式可以有，但在报告里标「无交叉验证」。
还要沿用 `CLAUDE.md` 的教训：Tesseract 当第三引擎因复核量 ×6 被否决，VLM 当第三引擎同样要先用数据过关（Phase 1）。

### 2.3 加速：每种运行时实际能用到的硬件

| 运行时 | 用到的硬件 | 用在哪 |
|---|---|---|
| Vision 框架 | 系统自动调度 ANE/GPU | Vision 引擎 |
| Core ML（`MLComputeUnits.all` / `.cpuAndNeuralEngine`） | **ANE** / GPU / CPU | PP-OCRv6 det/rec、PP-DocLayoutV3（转成 `.mlpackage`） |
| ONNX Runtime + CoreML EP | ANE/GPU（不支持的算子回落 CPU） | Paddle 模型转 Core ML 失败时的兜底 |
| llama.cpp（Metal） | GPU | 三个 VLM 的 GGUF |
| MLX | GPU（**不用 ANE**） | 可选 VLM 运行时 |
| 在线 API | 远端 | — |

要点：**ANE 只对小的卷积/CTC 模型现实可用**；0.8B~1B 的 VLM 在 Mac 上实际跑在 Metal GPU。
`AccelerationProbe` 在启动时探测芯片、可用内存、Core ML 能否把模型放上 ANE，结果写进质量报告，
「用了什么硬件」必须可见，不能只是一个开关。

## 3. 目标架构

```
DocOCR.xcodeproj / Package.swift
├── OCRCore            纯 Swift，无 Apple 框架依赖（Linux 上也能跑单测）
│   ├── Model           Page / Line / BBox / Reading / Flag，JSON 契约（与现有 *.vision.json 兼容）
│   ├── Normalize       equiv()：△ 读法、省略号折叠（NFKC 之后）… 原样移植
│   ├── Fuse            N 引擎融合 + 裁决规则（book_fuse / crosscheck 移植）
│   ├── Align           整页 VLM 文本 ↔ 行框 序列对齐
│   ├── Layout          书籍段落化（book_md）/ 剧本版面（to_markdown）
│   └── Glossary        config/glossary.txt 格式不变
├── OCREngines         协议 GeometryEngine / TextReader + 各实现
│   ├── VisionEngine        VNRecognizeTextRequest
│   ├── PaddleEngine        PP-OCRv6 det/cls/rec，Core ML 优先、ORT 兜底
│   ├── LayoutEngine        PP-DocLayoutV3
│   └── VLMReader           Xiaomi-OCR-0 / MiniCPM-V / PaddleOCR-VL，提示词模板按模型配置
├── OCRRuntime         推理后端
│   ├── CoreMLRuntime / ORTRuntime
│   ├── LlamaCppRuntime     进程内，Metal
│   ├── MLXRuntime          可选（D3）
│   └── HTTPRuntime         OpenAI 兼容：本地服务 + 在线 API
├── OCRProviders       Provider 注册表、Keychain、外传同意闸门、限速/重试/费用估算
├── ModelStore         下载（HF / ModelScope）、sha256 校验、版本钉死、~/Library/Application Support
├── PDFOut             PDFKit + CoreGraphics 隐形文字层（取代 pymupdf）
├── ocr-cli            swift-argument-parser，对齐现有 books.sh / run.sh 开关
└── DocOCRApp          SwiftUI：批处理、模型管理、Provider 设置、质量报告、剧本线校对界面
```

数据契约沿用现有 JSON（只加字段不改字段）：这样 Phase 2 起就能拿现有 Python 产物逐字节对比，
新旧实现并行跑到 Phase 7 才下线 Python。

## 4. 分阶段 Workflow（每阶段有「过关门槛」，不过关不进下一阶段）

### Phase 0 · 冻结基准（在动任何代码之前）
- 从 `~/Desktop/Ignore/old/ocr-归档-2026-10-19/` 选金标准集：剧本若干页（含单源错误集中区）+ 真书 373 页抽样 + 合成做旧样本。
  人工校对过的成稿即真值。
- 用现行 Python 流水线跑一遍，记录：字符准确率、编辑距离、逐行取回率、分歧率/单源率、秒/页、峰值内存。
- 把 `CLAUDE.md`「不变量」每一条写成一个可执行用例（括号里的「实测后果」就是断言）。
- **门槛**：基准数字入库（`bench/baseline.json`），用例全绿。

### Phase 1 · 模型可行性实测（Mac 上，Python/命令行即可，不写产品代码）
- 矩阵：{Xiaomi-OCR-0, MiniCPM-V 4.7 1B, PaddleOCR-VL-1.6, PP-OCRv6, Vision} × {llama.cpp, MLX, Transformers-MPS, Core ML, ORT-CoreML} × {区域模式, 整页模式}。
- 每格量：CER、**编造率**（输出里原图没有的字）、**吞字率**、秒/页、峰值内存、实际落在 ANE/GPU/CPU 哪个上。
- 关键问题要用数据回答：
  1. 哪个 VLM 与 CTC 引擎的错误相关性最低（决定默认组合）？
  2. 区域模式的调用次数 × 单次延迟，373 页要多久？（现状 8.4 分钟）
  3. PP-OCRv6 转 Core ML 后能否上 ANE、精度是否掉？
  4. 第三引擎带来的复核量增幅 vs 多抓到的错（对照 Tesseract 的 ×6 / 2 错/页）。
- **门槛**：一张决策表 → 定默认引擎组合、默认运行时、D3 的最终答案。

### Phase 2 · Swift 骨架 + Vision 引擎 + CLI
- Package 结构、JSON 契约、`ocr-cli recognize`（只有 Vision）。
- **门槛**：同一批页图，Swift 版输出与现有 `bin/vision-ocr` 逐行一致。

### Phase 3 · 移植融合与产出（用 Vision + 现有 RapidOCR JSON 喂数据）
- Normalize / Fuse / Layout / Glossary / PDFOut 移植；Phase 0 的不变量用例改写成 XCTest。
- **门槛**：喂相同输入 JSON，Swift 产出的 md 与 Python 版逐字一致；可搜索 PDF 逐行取回率 1.0000，原图字节 md5 不变。

### Phase 4 · Paddle 引擎（PP-OCRv6 + PP-DocLayoutV3）
- 开发期脚本 `tools/convert_paddle.py`：paddle2onnx → coremltools，产出 `.mlpackage` + sha256 清单。
  用户自己微调的 Paddle 模型也走这个脚本导入。
- **门槛**：金标准集上与 RapidOCR（同为 PP-OCRv6）精度持平；记录 ANE 命中率与速度。此时 Python 依赖已可整体去掉。

### Phase 5 · VLM 读字引擎（本地）
- `LlamaCppRuntime` + 三个模型的提示词模板、区域/整页两种模式、`Align` 对齐。
- 融合层从 2 引擎扩到 N 引擎；VLM 与 CTC 不一致时**默认信 CTC 的字形、信 VLM 的断句**（初始规则，Phase 1 数据为准）。
- **门槛**：默认组合在金标准集上 ≥ Phase 0 基准，且编造率有专门指标（自校验指标不能和失效模式同向）。

### Phase 6 · Provider 层（本地服务 + 在线 API）
- `HTTPRuntime`（OpenAI 兼容），预设：Ollama、LM Studio、llama-server、mlx-vlm、以及你指定的在线服务商。
- 外传闸门：逐文件同意、列出将发送的页、费用预估、发送日志；Keychain 存 key；本地失败**不**自动切在线。
- **门槛**：断网时一切本地功能可用；未同意时在线 provider 发不出任何请求（用例断言）。

### Phase 7 · SwiftUI App
- 批处理队列、进度、质量报告、模型管理（下载/校验/删除）、Provider 设置、加速探测面板、剧本线原生校对界面（取代 HTML 校对页）。
- **门槛**：现有 `.app` 的全部功能对齐；Python 实现下线。

### Phase 8 · 打包发布
- Xcode archive → 签名 → 公证 → 沿用 `packaging/release.sh` 的发布流程；模型不进 .app，首次启动按需下载。
- **门槛**：干净机器上首次启动到跑完一份样本全程无需终端。

## 5. 风险

| 风险 | 应对 |
|---|---|
| VLM 编造/润色，逐字精确目标被破坏 | 2.2 的 CTC 必选 + 编造率指标；VLM 结果永远可追溯到原图区域 |
| 区域模式太慢 | 块级（版面块）裁图代替行级；批量推理；Phase 1 用数据决定 |
| Xiaomi-OCR-0 的 GGUF 是社区转换、未经官方验证 | Phase 1 与 Transformers-MPS 原版逐页对比后再定；模型文件 sha256 钉死 |
| PP-OCRv6 部分算子上不了 ANE | ORT-CoreML EP 兜底；如实报告落在哪个硬件 |
| 在线 API 违背原有隐私承诺 | D2：默认关 + 显式同意 + 文档同步更新 |
| 全量重写丢掉旧代码里沉淀的细节 | 新旧并行到 Phase 7；以 JSON 契约 + 不变量用例做逐字对拍 |

## 6. 执行环境说明

本次规划所在的云端容器是 Linux，**没有 Xcode / Swift 工具链，也访问不到你 Mac 上的归档数据**。
所以：`OCRCore`（纯逻辑）可以在这里写并配 Linux Swift 单测；涉及 Vision / Core ML / Metal / PDFKit /
SwiftUI 的部分只能在这里写代码，**编译、实测和 Phase 0/1 的基准必须在你的 Mac 上跑**。

## 参考

- Xiaomi-OCR-0：<https://huggingface.co/xiaomi-research/Xiaomi-OCR-0>，技术报告 <https://arxiv.org/abs/2609.36136>，社区 GGUF <https://github.com/xzl01/Xiaomi-OCR-0-GGUF/releases/tag/v1.0.0>
- MiniCPM-V：<https://github.com/openbmb/MiniCPM-V>
- PaddleOCR-VL on Apple Silicon：<https://www.paddleocr.ai/latest/version3.x/pipeline_usage/PaddleOCR-VL-Apple-Silicon.html>
