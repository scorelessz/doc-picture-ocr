# Phase 6 结果：Provider 层

设计见 `docs/P6_DESIGN.md`。代码在 `mac/Sources/OCRProviders`，第 10 节的前四步已完成，App 确认窗放到 Phase 7。

## 怎么用

```bash
ocr-cli provider list                               # 只是可选列表，默认一家都不启用
ocr-cli provider key set dashscope                  # Key 从 stdin 读，存 Keychain
ocr-cli provider probe dashscope --model 名 --allow-network          # 只发合成图
ocr-cli book 书.pdf --vlm-provider dashscope --vlm-model 名 --allow-network
ocr-cli adjudicate 书.fused.json --provider deepseek --model 名 --mode text --out 新.json --allow-network
```

交互运行时要手动输入完整域名。非交互运行先不带确认跑一次，拿到清单 sha256，再加 `--confirm-upload <sha>`。

## 与设计稿的差异

- 模型下载走 `ModelDownload.fetch`，不走 `Payload`：响应要落文件。地址和每一跳重定向都过白名单。
- `Payload.probe` 收 `ProbeRequest`，请求体由它自己生成，不接受外部 `body`，比设计稿更严。
- 整个 target 依赖 CryptoKit，只在 Apple 平台编译。设计稿说闸门可以在 Linux 上测，这一点没有做到。
- 在线裁决是独立的 `adjudicate` 子命令，处理做完的 `fused.json`。分歧行要 OCR 之后才知道，这样确认仍在第一个请求之前。
- 候选的展示顺序由 id 决定并打乱，当前读法不总排第一，防止模型偏向第一个。

## 能力探测实测（只发合成图）

| 服务商 | 模型 | 支持图片 | 最大长边 | 稳定性 |
|---|---|---|---|---|
| 百炼 | qwen3.7-flash | 是 | 4096 | 3/3 |
| 硅基流动 | Qwen/Qwen3-VL-32B-Instruct | 是 | 4096 | 3/3 |
| 硅基流动 | Qwen/Qwen3-VL-8B-Instruct | 否 | - | 3/3 判不支持，实际是读不准 |
| DeepSeek | deepseek-flash | 不稳定 | 512–1792 | 回答形式多变，有时为空 |

探测判的是「收到图了吗」，不是读得准不准：随机码差 2 个编辑以内就算收到。好模型也会读错一位，精确相等会间歇误判。
DeepSeek flash 确实能看图（512 档 6 位全对），但结果不稳定，只用于纯文本。

## 端到端实测

样本是 `失约之城` 的 3 页。

| 场景 | 结果 |
|---|---|
| 不加 `--allow-network` | 退出码 2，无请求 |
| 非交互未确认 | 退出码 3，无 OCR 产物，请求体已删 |
| 错误的 sha | 拒绝，任务不开始 |
| 正确的 sha | 3 页上传成功，上传记录先写后发，写进报告 |
| 默认 `book` | 日志里没有 `provider_*` 和 `gate_*` 事件 |
| 看图裁决（qwen3.7-flash） | 24 处选定 24，改读法 1 |
| 文本裁决（deepseek-flash） | 修顺序前跑的：24 处选定 20，4 处请求失败 |
| 模型下载（全新目录） | 两个包都装好，重装 Core ML 包后 `vl/` 保留 |

看图裁决改的那一处没有对真值核实。

## 断网

没有关网卡：这台 Mac 上还有别的会话，而且断网后无法远程恢复。改用 `sandbox-exec` 禁止进程的 TCP、UDP 和 IP 出站，对照确认沙箱内 `curl` 连不上、沙箱外正常，`models fetch` 在沙箱内失败。
这证明的是「这个进程不联网也能完成」，比关网卡更严，但没有覆盖系统层面断网时框架的行为。

| 项 | 结果 |
|---|---|
| `doctor` | 全过 |
| 中文全书 | 373 页，183 秒，无降级，无引擎失败，无网络事件，md 与联网时逐字节一致 |
| 英文全书（`--force-ocr`） | 328 页，227 秒，无降级，无引擎失败，无网络事件 |
| 进程内 `--vlm` | 3 页，11.5 秒/页 |

## 单测清单

设计稿第 9 节的 42 条：

| 状态 | 条目 |
|---|---|
| 单测已覆盖 | 2–6、9–33、34–41 |
| 实跑验证 | 1（默认 `book` 无网络事件） |
| 实跑验证 | 7（见「断网」一节） |
| 单测 + 实跑 | 42（`reconcileUploads`，`book` 自动对账，也可用 `ocr-cli verify-uploads`） |
| 未做 | 8（在线裁决是独立命令，关闭时无代码路径，未单独写测试） |

总开关和选中相关：总开关关时所有非本机负载被拒、未选中的服务商即使有 Key 也零调用、任何失败都不换家，都有单测，断言的是最底层 `WireClient` 的调用计数。

`./dev/check.sh p6` 跑全部单测，并检查 `URLSession` 只出现在 `Transport.swift`。
