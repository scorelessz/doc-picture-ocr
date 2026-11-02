# DocOCR

书籍扫描件 PDF → 原图不动、叠隐形文字层的可搜索 PDF，以及段落化 Markdown。Mac 原生，默认全部在本机处理，不联网。

没有人工校对环节，质量报告是唯一的质量抓手。设计见 `docs/REFACTOR_PLAN.md`，数据契约见 `docs/DATA_CONTRACT.md`。
旧 Python 实现已下线，留在 git tag `python-final`。

## Mac App

### 从 zip 安装

`packaging/build_app.sh` 生成 `dist/DocOCR-版本-构建号.zip`。解压后把 `DocOCR.app` 拖进「应用程序」或 `~/Applications`，需要 Apple Silicon 和 macOS 14 以上。

这个 App 只有本机签名（ad-hoc），没有公证。**拷到别的 Mac 后**系统会拦下，用下面任一方法打开：

- 右键点图标 → 打开，在弹窗里再点一次「打开」。新版 macOS 如果没有这个选项，到「系统设置 → 隐私与安全性」点「仍要打开」。
- 或在终端运行：`xattr -dr com.apple.quarantine /Applications/DocOCR.app`

几点说明：

- App 默认不带模型。第一次打开时在主界面下载识别模型（约 139 MB），或用「从文件导入」选 `DocOCR-models-v1.zip`。高精度模式的模型在设置里按需下载，约 1.1 GB。自用打包可以加 `--with-models`。
- 每个新版本第一次访问「桌面」「文稿」时，系统都会询问一次，这是正常的。用文件选择窗或拖入的文件不会问，但默认输出目录在「文稿」下。
- 换版本后，之前保存的 API Key 需要在设置里授权一次或重新填写。

App 和命令行的功能对照见 `docs/P7_RESULTS.md`。

### 从源码运行

需要 macOS 14+、Xcode 和 Metal Toolchain（`xcodebuild -downloadComponent MetalToolchain`）。还没有签名和打包，先在本机运行：

```bash
swift build -c release
.build/release/DocOCRApp
```

首次打开选「仅本地使用」或「允许联网」，然后在设置 → 模型下载识别模型。默认不联网，用户文件不离开这台 Mac。
详情见 `docs/P7_RESULTS.md`。

## 命令行

```bash
swift build -c release
.build/release/ocr-cli models fetch
.build/release/ocr-cli book 书.pdf --outdir output --workdir work
```

## 许可证

本项目代码采用 PolyForm Noncommercial 1.0.0，见 `LICENSE`。第三方组件见 `docs/THIRD_PARTY_LICENSES.md`。
