# 第三方组件与许可证清单

用途声明：本项目**不盈利，仅限内部与个人使用**（用户 2026-11-01）。这份清单用于合规核对，不是法律意见。
「待核实」项以实际所用版本的 LICENSE 文件 / 模型卡 `license` 字段为准。

## 最终 App（Swift）会带上的

| 组件 | 用途 | 许可证 | 备注 |
|---|---|---|---|
| Apple Vision / PDFKit / Core ML / CoreGraphics | 识别、渲染、嵌字、推理 | Apple SDK 许可 | 系统框架，不随 App 分发 |
| mlx-swift 0.33.0（ml-explore） | PaddleOCR-VL 进程内推理 | MIT（已核对 LICENSE） | 分发时保留版权声明 |
| mlx、mlx-c（mlx-swift 内置） | 同上 | MIT（已核对 LICENSE） | 同上 |
| metal-cpp（mlx-swift 内置） | 同上 | Apache-2.0（已核对 LICENSE） | 分发时附 LICENSE |
| {fmt}（mlx-swift 内置） | 同上 | MIT 风格，带二进制例外（已核对 LICENSE 开头） | 同上 |
| nlohmann/json（mlx-swift 内置） | 同上 | MIT（已核对 LICENSE） | 同上 |
| swift-numerics 1.1.1（Apple） | mlx-swift 传递依赖 | Apache-2.0（已核对 LICENSE） | 分发时附 LICENSE |
| PP-OCRv6（PaddleOCR，转 Core ML） | 检测 + 识别 | Apache-2.0 | 转换后的模型仍属衍生作品，附 LICENSE |
| PaddleOCR-VL-1.6 | 整页读字（可选高精度） | Apache-2.0（官方模型卡，有 LICENSE 文件） | 用的是社区 MLX 8bit 转换，模型卡同为 Apache-2.0，用户自行下载 |

## 只在开发 / 测试期用到的

| 组件 | 许可证 | 备注 |
|---|---|---|
| pymupdf（Python 旧链路） | **AGPL-3.0** / 商业双授权 | 只在旧 Python 链路；仓库只写依赖名不附带它。Swift 版已用 PDFKit 取代。旧链路删除后此项消失 |
| RapidOCR / onnxruntime / opencv-python / numpy / Pillow / rapidfuzz | Apache-2.0 / MIT / Apache-2.0 / BSD / HPND / MIT | 均为宽松许可 |
| llama.cpp、mlx-vlm | MIT | P1 实测用 |
| mlx-swift-lm | MIT | 只克隆作结构参考，没有构建，不是依赖，不进 App |
| Xiaomi-OCR-0 | Apache-2.0 | 社区 GGUF 转换的模型卡字段；上游见下方核实表 |
| MiniCPM-V 4.7 1B | Apache-2.0 | 已核实，见下方 |
| MinerU2.5-Pro-2605 1.2B | Apache-2.0 | 已核实，见下方。**不要与 MinerU2.5-2509 混淆，那个是 AGPL-3.0**。MinerU 软件本体未核实，本项目也没有使用 |
| OvisOCR2 | Apache-2.0 | 已核实，见下方 |
| Droid Sans Fallback（旧 Python 嵌字字体） | Apache-2.0 | Swift 版改用自生成空字形字体 |

## 模型许可证核实（2026-11-01）

来源是 Hugging Face 模型卡的 `license` 字段，下表的 revision 是核实时的 commit 前 12 位。模型卡字段是发布者自己声明的，不是法律结论。

| 模型 | 上游仓库 | revision | license | LICENSE 文件 | 本机转换版 |
|---|---|---|---|---|---|
| MinerU2.5-Pro-2605 1.2B | `opendatalab/MinerU2.5-Pro-2605-1.2B` | `08aaea840498` | apache-2.0 | 无 | `OpenGryd/…-MLX-8bit`，apache-2.0 |
| OvisOCR2 | `ATH-MaaS/OvisOCR2` | `cbdede82e048` | apache-2.0 | 有，README 也有声明 | `mlx-community/OvisOCR2-8bit`，apache-2.0 |
| MiniCPM-V 4.7 1B | `openbmb/MiniCPM-V-4.7-1B` | `ad9bf379feb7` | apache-2.0 | 无 | `openbmb/MiniCPM-V-4.7-1B-gguf`，apache-2.0 |
| PaddleOCR-VL-1.6 | `PaddlePaddle/PaddleOCR-VL-1.6` | `c5630abae1d9` | apache-2.0 | 有 | `OpenGryd/…-MLX-8bit`，apache-2.0 |

对比项：`opendatalab/MinerU2.5-2509-1.2B` 的 license 是 agpl-3.0，确认与 Pro-2605 不同。

OvisOCR2 的基座 `Qwen/Qwen3.5-0.8B` 也是 apache-2.0。

未决：Xiaomi-OCR-0 的上游 `SeerRay-Lab/Xiaomi-OCR-0` 这次查询没有返回可解析的结果，社区 GGUF 模型卡写的是 apache-2.0，上游未确认。它只在 P1 测试用过，不进 App。
PP-OCRv6 和 PaddleOCR 的 Apache-2.0 这次没有重新核对。

`Package.resolved` 只有 `mlx-swift` 和 `swift-numerics` 两项。mlx-swift 内置代码的许可证看的是 `.build/checkouts/mlx-swift` 里的 LICENSE 文件。

## 在线服务

百炼、硅基流动、DeepSeek、OpenRouter、Anthropic：受各自服务条款约束（用量、内容、数据处理）。
App 默认不联网，任何一家都要用户亲自选择、当次确认后才会调用（见 `docs/P6_DESIGN.md`）。

## 样本书

两本基准书受版权保护，只在用户本机用于开发测试，不进仓库（仓库只存数字结果）。

## 本项目自身代码

**PolyForm Noncommercial License 1.0.0**（用户 2026-11-01 选定，见根目录 `LICENSE`）：允许非商业使用、修改、分发，禁止商用。
它只覆盖本项目自己的代码；上表各组件仍按各自许可证。所有依赖均为宽松许可或系统框架，与之不冲突。
