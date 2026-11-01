# 第三方组件与许可证清单

用途声明：本项目**不盈利，仅限内部与个人使用**（用户 2026-11-01）。这份清单用于合规核对，不是法律意见。
「待核实」项以实际所用版本的 LICENSE 文件 / 模型卡 `license` 字段为准。

## 最终 App（Swift）会带上的

| 组件 | 用途 | 许可证 | 备注 |
|---|---|---|---|
| Apple Vision / PDFKit / Core ML / CoreGraphics | 识别、渲染、嵌字、推理 | Apple SDK 许可 | 系统框架，不随 App 分发 |
| mlx-swift（ml-explore） | PaddleOCR-VL 进程内推理 | MIT | 分发时保留版权声明 |
| mlx-swift-lm（ml-explore） | 同上（参照结构） | MIT | 同上 |
| swift-numerics（Apple） | mlx-swift 传递依赖 | Apache-2.0 | 分发时附 LICENSE / NOTICE |
| PP-OCRv6（PaddleOCR，转 Core ML） | 检测 + 识别 | Apache-2.0 | 转换后的模型仍属衍生作品，附 LICENSE |
| PaddleOCR-VL-1.6 | 整页读字（可选高精度） | Apache-2.0（官方模型卡） | 用的是社区 MLX 8bit 转换，许可证继承原模型 |

## 只在开发 / 测试期用到的

| 组件 | 许可证 | 备注 |
|---|---|---|
| pymupdf（Python 旧链路） | **AGPL-3.0** / 商业双授权 | 只在旧 Python 链路；仓库只写依赖名不附带它。Swift 版已用 PDFKit 取代。旧链路删除后此项消失 |
| RapidOCR / onnxruntime / opencv-python / numpy / Pillow / rapidfuzz | Apache-2.0 / MIT / Apache-2.0 / BSD / HPND / MIT | 均为宽松许可 |
| llama.cpp、mlx-vlm | MIT | P1 实测用 |
| Xiaomi-OCR-0 | Apache-2.0 | 社区 GGUF 转换，继承原许可 |
| MiniCPM-V 4.7 | Apache-2.0（项目页声明） | 待核实模型卡 |
| MinerU2.5-Pro-2605 | Apache-2.0（二手来源） | **待核实**：早期 MinerU2.5-2509 是 AGPL-3.0，MinerU 软件本体是自定义许可 |
| OvisOCR2 | **待核实** | 未查到官方声明 |
| Droid Sans Fallback（旧 Python 嵌字字体） | Apache-2.0 | Swift 版改用自生成空字形字体 |

## 在线服务

百炼、硅基流动、DeepSeek、OpenRouter、Anthropic：受各自服务条款约束（用量、内容、数据处理）。
App 默认不联网，任何一家都要用户亲自选择、当次确认后才会调用（见 `docs/P6_DESIGN.md`）。

## 样本书

两本基准书受版权保护，只在用户本机用于开发测试，不进仓库（仓库只存数字结果）。

## 本项目自身代码

尚未选定许可证（见对话中的建议）。未选定前默认「保留所有权利」：仓库公开可见，但他人没有使用、修改、再分发的授权。
