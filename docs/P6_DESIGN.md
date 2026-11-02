# Phase 6 设计稿：Provider 层与上传确认

依据 `docs/REFACTOR_PLAN.md` §3。这是设计稿，还没有写代码。门槛：断网时本地功能全可用；未确认时零外发请求。

## 1. 要守住的规则

1. 用户文件的任何字节离开本机，都必须持有本次操作确认过的票据。
2. 本地失败绝不自动转在线；在线失败不换另一家（新域名没有被确认过），保留本地结果并标记。
3. 不确认，任务不开始，不降级成本地跑一半。
4. 没有「永久不再询问」，确认状态不落盘。
5. Key 只在 Keychain，不进设置文件、日志、命令行参数和报告。
6. 能力探测只发程序生成的合成图。
7. 裁决结果只能在候选之间选，不能写入候选里没有的字。

8. **联网总开关（用户 2026-11-01 要求）**：程序第一次启动、进入任何功能之前，先用**红字**提示数据上传问题
   （见第 1.1 节）。用户没有明确选择「允许联网」之前，所有联网相关选项（在线识别、在线裁决、服务商设置、
   测试连接）一律**灰掉不可点**，代码层面 `HTTPTransport` 也拒绝任何非本机请求。
9. **每一家服务商都必须用户亲自选择才生效**（含 Anthropic）：预置只是「可选列表」，默认一家都不启用；
   绝不自动回退、自动换家、自动调用。用户没选的服务商，哪怕配了 key 也不会被调用。

规则 1、6 靠类型保证，不靠调用方自觉，见第 3 节。

### 1.1 启动时的联网提示与总开关

- 首次启动先弹一屏说明（不能跳过），红字写明：
  「开启联网功能后，你选中的页面图片或文字片段会被上传到你选择的服务商。默认不开启，不开启时所有处理都只在本机完成。」
- 两个按钮：「仅本地使用（推荐）」/「我了解风险，允许联网功能」。前者是默认焦点。
- 选「仅本地」：联网总开关 = 关。设置里所有联网选项灰掉，旁边写原因并给「去开启」入口（再走一次同样的红字确认）。
- 选「允许联网」：只是**解锁**选项，不启用任何服务商；每次真正上传仍走第 4 节的逐次确认窗。
- 总开关状态可随时关掉；关掉立即生效，进行中的在线请求取消，已排队的不发。
- 总开关的状态可以落盘（它只决定「能不能看见选项」），但逐次上传确认仍不落盘（规则 4）。
- 命令行：默认联网关闭；要用在线功能必须显式 `--allow-network`，且每次运行仍需确认（非交互时用 `--confirm-upload <清单 sha256>`，清单不符拒绝）。
- 例外说明：**模型下载**（`models fetch`）只下载、不上传任何用户文件，单独列出，按钮文字写明「仅下载模型，不上传文件」；**不受总开关约束**（用户 2026-11-01 选方案 B）：模型下载单独放行，只允许连钉死的下载地址（GitHub Release / Hugging Face），只做 GET，请求体为空，不带任何用户数据；实现为 `ModelDownload.fetch(url, to:)`（响应要落文件，不走 `Payload`），地址和每一跳重定向都过白名单，不在白名单直接拒绝。
- 单测：总开关关时，任何 `Payload`（包括 `.probe`、`.metadata`）对非本机地址都在 `HTTPTransport` 层被拒，网络层调用计数为 0。


## 2. 模块划分

新增 target `OCRProviders`，依赖 `OCRCore`。`OCRCore` 继续不碰网络，确认闸门的逻辑是纯状态机，可以在 Linux 上测。

| 文件 | 内容 |
|---|---|
| `Endpoint.swift` | `Endpoint`、本机判定 |
| `Transport.swift` | `HTTPTransport` 协议和唯一的 `URLSession` 实现 |
| `UploadGate.swift` | 状态机、`UploadManifest`、`UploadTicket` |
| `Provider.swift` | `VisionReader`、`TextAdjudicator` 协议，OpenAI 兼容适配，Anthropic 适配 |
| `Capability.swift` | 能力档案、探测、`SyntheticImage` |
| `Secrets.swift` | `SecretStore`、Keychain 实现、`SecretKey` |
| `Adjudication.swift` | §3.3 在线裁决 |

## 3. Swift 接口

### 3.1 端点

```swift
public struct Endpoint: Sendable, Hashable {
    public let baseURL: URL
    public let host: String              // 小写，确认窗显示的就是它
    public var isLoopback: Bool          // 仅 localhost、127.0.0.0/8、::1
    public init(_ raw: String) throws    // 非本机必须 https；URL 带用户名密码时拒绝
}
```

局域网地址（`192.168.x.x`、`mymac.local`）算非本机，要走确认。`--vlm-url` 现有的本机判定改用这里的 `isLoopback`。

### 3.2 网络层

```swift
public protocol HTTPTransport: Sendable {
    func send(_ r: OutboundRequest) async throws -> HTTPReply
}

public enum Payload: Sendable {
    case userData(body: Data, ticket: UploadTicket, itemID: String)   // 用户内容
    case probe(body: Data, proof: SyntheticImage?)                    // 探测，图只能是合成图
    case metadata                                                     // GET /models
    case loopback(body: Data)                                         // 只发本机
}

public struct OutboundRequest: Sendable {
    public let endpoint: Endpoint, path: String, payload: Payload, key: SecretKey?
}
```

`URLSessionTransport` 是工程里唯一发 HTTP 的实现，发送前按顺序检查：

- `.userData`：票据有效，请求 host 等于 `ticket.host`，`itemID` 在清单内，累计字节不超过清单上限；
- `.loopback`：`endpoint.isLoopback` 必须为真；
- 任一不过就抛 `TransportError.refused`，不发送。

会话配置：`ephemeral`，`urlCache = nil`，不存 cookie，图片不落磁盘。

**重定向默认拒绝**：`willPerformHTTPRedirection` 跨 host 时返回 nil 并报错。否则一个 302 就能把图片送到确认窗没写过的域名。

现有 `vlmRead` 里的 `URLSession.shared` 迁到 `.loopback`。`ModelStore` 的下载只取模型、不发用户内容，保留但移到同一文件。

### 3.3 确认闸门

```swift
public struct UploadItem: Sendable {
    public let id: String, sourceFile: String, page: Int, bytes: Int
}

public struct UploadManifest: Sendable, Equatable {
    public let providerName: String, host: String, model: String
    public let items: [UploadItem]
    public let estimatedRequests: Int
    public let estimatedCost: Cost               // .unknown 时确认窗写「未知」
}

public struct UploadTicket: Sendable {           // init 是 internal，只有 UploadGate 能发
    public let id: UUID, host: String, scope: Scope
    fileprivate let digest: Data                 // 清单摘要，改了清单票据即失效
}

public enum Scope: Sendable { case once, batch(UUID) }

public actor UploadGate {
    public func request(_ m: UploadManifest) -> GateState
    public func confirm(checkbox: Bool, scope: Scope) throws -> UploadTicket
    public func decline()
    public func finish()                         // 任务或批次结束，票据作废
}
```

`UploadTicket` 的构造函数不公开，其他模块造不出来。测试通过 `@testable` 用 `UploadGate` 的正常路径取票，不开后门。

### 3.4 Provider

```swift
public protocol VisionReader: Sendable {
    func read(_ image: Data, prompt: String, ticket: UploadTicket, itemID: String) async throws -> String
}

public protocol TextAdjudicator: Sendable {
    func choose(_ q: AdjudicationQuestion, ticket: UploadTicket) async throws -> AdjudicationAnswer
}
```

本地 `PaddleVL`、Vision 不走这组协议，不需要票据；本地 HTTP 服务走 `.loopback`。这样本地路径里没有任何在线分支可以落入。

## 4. 确认闸门状态机

```
idle ── request(m) ──> awaitingConfirm(m)
                         │  decline / 关窗 ─> declined ─> 任务不开始（终态）
                         │  confirm(checkbox: false) ─> 抛错，留在 awaitingConfirm
                         │  confirm(checkbox: true)
                         v
                       confirmed(ticket)
                         │  开始发送
                         v
                       running(ticket) ── 清单或 host 变化 ─> revoked ─> awaitingConfirm(新清单)
                         │  全部完成 / 失败 / 取消
                         v
                       finished ─> finish() ─> idle（票据作废）
```

| 情况 | 处理 |
|---|---|
| 本机地址 | 不进闸门，走 `.loopback` |
| 「本批次内不再询问」 | 只对同一批、同一 host、同一模型有效，只在内存里；下一个文件的 `request` 直接发新票据，上传记录照写 |
| 批次中换 provider、host 或模型 | 重新询问 |
| 中途需要多传（如重试把字节推过上限） | 票据失效，重新询问，不静默扩大范围 |
| App 退出或崩溃 | 确认状态消失，下次重新询问 |
| 限流重试 | 同一 `itemID` 的重试不算新条目，但字节计入累计，超限走上一行 |
| 本地引擎失败 | 按现有降级写进报告，不触发 `request` |
| 在线请求失败 | 该项保留本地结果并标记，任务继续，不换服务商 |

CLI 没有确认窗，等价做法：在终端打印与确认窗相同的内容，要求手动输入完整域名。stdin 不是 TTY 时拒绝。**不提供 `--yes` 之类的参数**，否则一行脚本就绕过了「手动勾选」。

确认窗内容按 §3.2：服务商、域名、文件名、页数、总大小、请求数、费用；§3.3 改写「N 处分歧，约 M 字 / K 张裁切图」。勾选前「开始」不可点。

## 5. Keychain

```swift
public struct SecretKey: Sendable, CustomStringConvertible {
    public var description: String { "<redacted>" }   // 不实现 Encodable
    let value: String                                 // 只有 Transport 读取
}

public protocol SecretStore: Sendable {
    func load(_ providerID: String) throws -> SecretKey?
    func save(_ key: String, for providerID: String) throws
    func delete(_ providerID: String) throws
}
```

- 类型 `kSecClassGenericPassword`，service 为 `com.dococr.provider`，account 为 provider ID；
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，`kSecAttrSynchronizable = false`，不进 iCloud 钥匙串和备份；
- 设置文件只存 provider ID、Base URL、模型名，不存 Key；
- `ocr-cli provider key set <id>` 从 stdin 关回显读入，不接受参数和环境变量；
- 测试用内存版 `SecretStore`，单测不碰真实 Keychain。

## 6. 能力探测

「测试连接」由用户点击触发。发送的是 Key 和合成图，不含用户内容，所以不走上传确认，但界面写明会连接哪个域名。

```swift
public struct SyntheticImage: Sendable {          // init 不公开，只能由生成器产生
    public let png: Data, code: String
    public static func make(width: Int, height: Int) -> SyntheticImage
}

public struct CapabilityProfile: Codable, Sendable {
    public var providerID, model: String
    public var probedAt: Date
    public var supportsImage: Bool
    public var maxLongEdge: Int?                  // 通过的最大边长
    public var maxBytes: Int?
    public var responseFormat: ResponseFormat     // .text / .jsonObject
    public var pricePerMTokens: Price?            // 用户可填，缺失时费用写「未知」
}
```

步骤：

1. `GET /models`，失败时允许手填模型名；
2. 用 `CoreGraphics` 画一张含 6 位随机码的白底图，要求模型读出。随机码防止只支持文本的模型靠编造蒙对；
3. 按 512、1024、1792、2048、4096 递增，第一次失败就停，得到 `maxLongEdge`；
4. 发一个要求 JSON 输出的请求，记录是否支持；
5. 存到 `Application Support/DocOCR/providers/<id>.json`，不含 Key。

`Payload.probe` 只收 `SyntheticImage`，页面图没有办法变成这个类型。

## 7. 在线裁决（§3.3）

默认关，开启处写明「数据会被上传」。

```swift
public struct AdjudicationQuestion: Sendable {
    public let id: String, page: Int, candidates: [String]
    public let crop: Data?                        // 看图裁决：只裁分歧行，上下留白不超过行高的 25%
    public let context: [String]                  // 纯文本裁决：前后各一行
}

public enum AdjudicationAnswer: Sendable {
    case chosen(index: Int, evidence: Evidence)   // .image 或 .textOnly
    case undecided(reason: String)
}
```

- 提示词要求返回 `{"choice": 序号}`。序号越界、无法解析、返回文字而不是序号，一律算 `undecided`，保留本地读法并标记。协议里没有自由文本字段，写不进新字；
- 纯文本裁决结果标「仅文本依据」，不用于形近字；
- 整本的量不小：P5 的两本书分别有 4229 和 2521 个分歧行。确认窗要写真实数量和费用，并允许用户限定页范围或只裁决字母数字差异；
- 融合结果增加 `adjudication` 字段（来源、模型、依据、原读法），质量报告逐条列出。

§3.3 提到 DeepSeek，§3.1 的预置表没有列，实现时补进预置。Anthropic 不是 OpenAI 兼容接口，要单独适配；用户目前不让测试调用 Anthropic API，所以这个适配只做 mock 测试，真实联调等用户另行同意。
Anthropic 与其他服务商一样，只是可选项：用户在设置里亲自选中、填了 key、并在当次确认窗勾选后才会被调用；任何失败都不会自动转到 Anthropic，也不会从 Anthropic 自动转到别家。

## 8. 上传记录与日志

上传记录**先写后发**，崩溃也不会漏记。写到 `<stem>.uploads.jsonl`，报告从中生成「上传记录」一节。

| 字段 | 说明 |
|---|---|
| `time` `host` `provider` `model` | 时间、域名、服务商、模型 |
| `ticket` | 票据 ID 前 8 位 |
| `scope` | `once` 或 `batch` |
| `page` `item` `bytes` | 页码、条目、字节数 |
| `status` | `pending` / `ok` / `failed:<错误类>` |

| 事件 | 级别 | 字段 |
|---|---|---|
| `gate_request` | info | `host` `items` `bytes` `requests` `cost` |
| `gate_decision` | info | `decision` `scope` `ticket` |
| `gate_revoked` | warn | `reason` `ticket` |
| `provider_request` | debug | `host` `model` `item` `bytes` `attempt` |
| `provider_response` | debug | `status` `seconds` `tokens_in` `tokens_out` `chars` |
| `provider_refused` | warn | `reason` `host` `item` |
| `redirect_blocked` | warn | `from` `to` |
| `probe_result` | info | `host` `model` `supports_image` `max_long_edge` |
| `adjudication` | debug | `page` `item` `result` `evidence` |

永远不写：Key、`Authorization` 头、请求体、图片、响应正文。候选文字只在 `--log-text` 时写。

## 9. 单测清单

**零外发（重点）**：全部用计数的 `MockTransport`，并断言真实 `URLSessionTransport` 的 URLProtocol 桩未被触发。

1. 默认设置跑完整本流程，网络调用 0 次；
2. `awaitingConfirm` 状态下调用 provider，调用 0 次；
3. `confirm(checkbox: false)` 抛错，调用 0 次；
4. `decline` 后任务不开始，调用 0 次，也没有本地半成品；
5. 关闭确认窗等同 `decline`；
6. 本地引擎抛错后不进闸门，调用 0 次；
7. 启用在线 provider 但断网，本地功能全部可用；
8. 关闭在线裁决时，有分歧行也是调用 0 次。

**票据**：

9. 票据的 host 与请求不符，拒绝；
10. `itemID` 不在清单内，拒绝；
11. 累计字节超限，拒绝，状态转 `revoked`；
12. `finish()` 后旧票据失效；
13. 清单变化后旧票据失效；
14. 一次性票据不能用于第二个文件；
15. 批次票据换 host 或模型后失效；
16. 新进程没有任何确认状态。

**传输**：

17. 跨 host 重定向被拦，第二个请求 0 次；
18. 同 host 重定向也要重新过票据检查；
19. 非本机 `http://` 在构造 `Endpoint` 时被拒；
20. `127.0.0.1.evil.com`、`localhost.evil.com` 不算本机；
21. `192.168.1.2` 不算本机；
22. `.loopback` 配非本机地址被拒；
23. 会话没有磁盘缓存。

**失败路径**：

24. 在线失败保留本地结果并标记，不调用第二家；
25. 重试的字节计入累计；
26. 5xx 和 429 的退避次数有上限。

**裁决**：

27. 返回序号越界算 `undecided`；
28. 返回自由文本算 `undecided`，正文不变；
29. 只有分歧行进入清单；
30. 看图裁决的裁切图不超过行高加留白；
31. 纯文本裁决的请求体不含图片；
32. 纯文本结果带 `textOnly` 标记。

**Keychain 与日志**：

33. `SecretKey` 的字符串插值输出 `<redacted>`；
34. 设置文件和能力档案里搜不到 Key；
35. 开 `trace` 跑 mock 全流程，日志里搜不到 Key 和测试正文；
36. 带 `--log-text` 时只多出候选文字，仍没有 Key。

**探测**：

37. 探测请求里的图来自 `SyntheticImage`，且随机码每次不同；
38. 模型答错随机码时 `supportsImage = false`；
39. 尺寸阶梯在第一次失败时停止；
40. `/models` 失败时可手填。

**记录**：

41. 上传记录先于请求写入，mock 在发送时抛错也有 `pending` 记录；
42. 报告的上传页码与 mock 收到的完全一致。

**工程检查**：`dev/check.sh` 增加一条：`URLSession` 只允许出现在 `Transport.swift`，其他文件出现就失败。

## 10. 实施顺序

1. `Endpoint`、`HTTPTransport`、`UploadGate` 和第 1–22 条测试，不接任何真实服务；
2. `SecretStore`、能力探测，用硅基流动和百炼联调，只发合成图；
3. OpenAI 兼容 `VisionReader`，接进 `book`；
4. §3.3 在线裁决；
5. App 确认窗放到 Phase 7，这里先做 CLI 等价流程和状态机。
