# Phase 8 结果：打包

没有 Apple 开发者账号，只做本机签名（ad-hoc），不做公证。`packaging/build_app.sh` 组装 `.app` 并打 zip，`packaging/release.sh` 默认发 Swift 版，发布前停下来询问，`--python` 走旧链路。

## 包内容

| 项 | 内容 |
|---|---|
| Bundle ID | `com.dococr.app` |
| 显示名 | 文档图片 OCR |
| 版本 | 最近的 git tag（现在是 1.0.0），构建号是提交数，`DocOCRGitCommit` 记 commit |
| 最低系统 | macOS 14 |
| 识别模型 | 20 个预编译 `.mlmodelc`，放 `Resources/models`，优先于 Application Support |
| VL 模型 | 不打包，按需下载到 Application Support |
| Metal 着色器 | `Resources/mlx-swift_Cmlx.bundle` |

包内只放 `.mlmodelc`：`.app` 只读，引擎不能现场编译，写进去还会破坏签名。

## 体积

| 项 | 大小 |
|---|---|
| `DocOCR.app` | 199 MB |
| 其中模型 | 162 MB |
| 其中可执行文件 | 32 MB |
| zip | 144 MB |

## 签名

| 检查 | 结果 |
|---|---|
| `codesign --verify --strict --deep` | 通过，运行后仍有效 |
| 签名类型 | adhoc，无 TeamIdentifier |
| `spctl -a` | rejected，没有公证的预期结果 |

## 启动时间

从 `open` 到窗口出现，从 zip 解压后的 `~/Applications/DocOCR.app`：0.24 / 0.29 / 0.27 秒。新构建的第一次是 0.74–1.36 秒。

## 冒烟

用 `open` 启动，走 Launch Services，和双击同一条路径；不是人工点击。输入放在 `/tmp`。

| 项 | 结果 |
|---|---|
| 两本书各 5 页 | 都完成，3 个产物，无降级，共 24 秒（新构建首次运行） |
| 主线程最长间隔 | 0.01 秒 |
| 中文 5 页 Markdown | 与 `.build` 版逐字节一致 |
| 高精度 5 页 | 完成，无降级，62 秒，确认包内 Metal 着色器能加载 |

## 隐私授权（TCC）

每个新构建都有新的 cdhash，系统当作新程序。第一次读「桌面」下的文件时会弹授权框，处理会一直等用户点。
冒烟里出现过两次：一次记录停在运行中，一次挂住 9 分钟，栈停在打开 PDF。把输入换到 `/tmp` 后，新构建首次运行正常，据此判断是这个原因。**弹窗本身没有看到**，这是推断。

通过文件选择窗或拖入的文件不走这个询问。默认输出目录在「文稿」下，第一次写入时可能询问一次，这时界面不卡，任务停在开始处。

## Keychain

条目绑定写入者的 cdhash。实测两个不同签名的包（改 `CFBundleVersion` 后重签）：

| 操作 | 改之前 | 改之后 |
|---|---|---|
| 另一个构建查状态 | 挂住 25 秒，弹系统框（`kSecUseAuthenticationUIFail` 不起作用） | 立即返回「需授权」，不弹框 |
| 另一个构建读取 | 同上 | 立即报需要授权 |
| 另一个构建覆盖保存 | 失败，`-25244`，非创建者不能删 | 成功 |
| 写入者查状态 | 可读 | 可读 |

做法：写入时把 cdhash 记进条目的 `kSecAttrGeneric`，读属性不用解密也不弹框，签名相同才试读。删除失败时改用系统的 `/usr/bin/security`，它不受创建者限制。

「授权读取旧 key」会弹系统框，需要人点，**没有实测**；授权成功后记录在 UserDefaults。ocr-cli 和 App 用同一套条目，但签名不同，互相读取时 ocr-cli 会弹框，App 显示需授权。

用户现有的 `dashscope`、`deepseek` 条目创建于 2026-11-01 21:46，创建者是 `.build/out/Products/Release/DocOCRApp`，后来重新构建后读不了。条目里没有写入者记录，新版显示「已保存但需授权」，可以授权或覆盖。

## 没有验证的

- 没有在另一台 Mac 上试过。隔离属性的提示没有实际触发，本机解压的文件没有 quarantine。
- 没有人工双击，`open` 只是同一条启动路径。
- 模型名下拉和 Key 状态界面只有单测，没有离屏渲染，也没有手动操作。
