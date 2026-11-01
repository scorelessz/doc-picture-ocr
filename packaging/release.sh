#!/usr/bin/env bash
# 发版：构建 → ad-hoc 签名 → 压缩 → 传到 GitHub Releases。默认发 Swift 版 DocOCR.app。
# 发布前会停下来问一次，不回答 y 就只留本地 zip。
#
#   packaging/release.sh 2.0.0 --python         发 Python 旧链路的 DocPictureOCR.app
#   packaging/release.sh 1.1.0                  重新构建并发布 v1.1.0
#   packaging/release.sh 1.0.0 --skip-build     直接发布 dist/ 里现成的 .app
#   packaging/release.sh 1.1.0 --draft          先发草稿, 自己确认后再 publish
#   packaging/release.sh 1.1.0 --notes-file x.md
#
# --skip-build 的用处：重新构建会改变二进制, macOS 的 Gatekeeper 放行是
# **按二进制**记住的 —— 重建一次就要重新放行一次。手上这个 .app 已经放行过、
# 也验证过, 那就别动它, 直接打包发出去。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

SKIP_BUILD=0; DRAFT=""; NOTES_FILE=""; VERSION=""; PY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --draft)      DRAFT="--draft"; shift ;;
    --python)     PY=1; shift ;;
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    -h|--help)    sed -n '2,16p' "$0"; exit 0 ;;
    -*)           echo "未知参数: $1"; exit 2 ;;
    *)            VERSION="$1"; shift ;;
  esac
done
[ -n "$VERSION" ] || { echo "用法: packaging/release.sh <版本号> [--skip-build] [--draft]"; exit 2; }
TAG="v$VERSION"
if [ "$PY" = 1 ]; then NAME=DocPictureOCR; else NAME=DocOCR; fi
APP="$ROOT/dist/$NAME.app"

say() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

# ── 前置检查：先把会失败的事情查出来, 别传到一半才发现 ──────────────
command -v gh >/dev/null || { echo "✗ 没装 gh (brew install gh)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ gh 没登录 (gh auth login)"; exit 1; }
git diff --quiet && git diff --cached --quiet || {
  echo "⚠ 工作区有未提交的改动 —— 发出去的 .app 和仓库里的代码会对不上。"
  echo "  先 commit, 或确认无妨后按回车继续。"; read -r
}
if git rev-parse "$TAG" >/dev/null 2>&1 || gh release view "$TAG" >/dev/null 2>&1; then
  echo "✗ $TAG 已经存在。换个版本号, 或先 gh release delete $TAG"; exit 1
fi

# ── 构建 ────────────────────────────────────────────────────────────
if [ "$SKIP_BUILD" = "1" ]; then
  [ -d "$APP" ] || { echo "✗ --skip-build 但 $APP 不存在"; exit 1; }
  say "跳过构建, 用现成的 $(basename "$APP")"
  HAVE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
  [ "$HAVE" = "$VERSION" ] || echo "  ⚠ 包里写的版本是 $HAVE, 这次发的是 $VERSION(只影响 Info.plist 里的字符串)"
else
  say "构建 $TAG"
  if [ "$PY" = 1 ]; then
    packaging/build.sh --version "$VERSION"
  else
    DOCOCR_VERSION="$VERSION" packaging/build_app.sh --keep-app
  fi
fi
codesign --verify --deep "$APP" 2>&1 | sed 's/^/  /' || { echo "✗ 签名校验不过"; exit 1; }

# ── 压缩：必须用 ditto ───────────────────────────────────────────────
#  zip -r 会破坏 .app 里 Framework 的符号链接, 解压出来的包打不开。
#  ditto -c -k --sequesterRsrc --keepParent 是 Apple 自己推荐的做法。
say "压缩"
ZIP="$ROOT/dist/$NAME-$VERSION-macOS-arm64.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIZE=$(du -h "$ZIP" | cut -f1)
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "  $ZIP  $SIZE"
echo "  sha256 $SHA"

# ── 发布说明 ────────────────────────────────────────────────────────
if [ -n "$NOTES_FILE" ]; then
  NOTES=$(cat "$NOTES_FILE")
elif [ "$PY" = 0 ]; then
  NOTES=$(cat <<EOF
书籍扫描件 OCR 的 Mac 原生版：可搜索 PDF（原图不动，叠隐形文字层）和段落化 Markdown。默认全部在本机处理，不联网。

## 安装

1. 下载 \`DocOCR-$VERSION-macOS-arm64.zip\`，解压后把 \`DocOCR.app\` 拖进「应用程序」
2. 这个 App 只有本机签名，没有公证。第一次打开：右键点图标 → 打开，或在终端运行
   \`\`\`
   xattr -dr com.apple.quarantine /Applications/DocOCR.app
   \`\`\`

需要 Apple Silicon 和 macOS 14 以上。App 不带模型，第一次打开时下载识别模型（约 139 MB）或从文件导入；高精度模式的模型约 1.1 GB。

sha256: \`$SHA\`
EOF
)
else
  NOTES=$(cat <<EOF
本地中文扫描件 OCR。把扫描件 PDF 丢进去, 得到**可搜索 PDF**(原图不动, 叠一层隐形文字层)
和**段落化 Markdown**。全部本地推理, 不联网、不上传。

## 安装

1. 下载 \`DocPictureOCR-$VERSION-macOS-arm64.zip\` 并解压
2. 把 \`DocPictureOCR.app\` 拖进「应用程序」
3. **首次打开**: 这个 app 没有 Apple 开发者签名, 从网上下载的包会被 Gatekeeper 拦下。
   在终端里去掉隔离属性即可:
   \`\`\`
   xattr -dr com.apple.quarantine /Applications/DocPictureOCR.app
   \`\`\`
   或者右键点图标 → 打开 → 在弹窗里再点一次「打开」。
4. 首次启动约 40 秒(系统要校验 285MB 的动态库并加载模型), 之后就快了。

## 环境要求

Apple Silicon 的 Mac(识别用到 macOS Vision 框架)。自依赖, 不需要装 Python。

## 实测

373 页中文书: 8.4 分钟 / 1.35 秒每页, 逐行取回率 1.0000, 人工抽查 1100 字 0 错。
峰值内存约 3.5GB。

sha256: \`$SHA\`
EOF
)
fi

# ── 发布：传上去就是公开内容，停下来问一次 ─────────────────────────────
say "发布 $TAG"
printf '确认把 %s 发布到 GitHub Release？输入 y 继续，其他输入只保留本地 zip: ' "$(basename "$ZIP")"
read -r ANSWER || ANSWER=""
[ "$ANSWER" = "y" ] || { echo "没有发布。zip 在 $ZIP"; exit 0; }
gh release create "$TAG" "$ZIP" \
  --title "$NAME $TAG" \
  --notes "$NOTES" \
  $DRAFT
echo
gh release view "$TAG" --json url,isDraft,assets \
  -q '"✓ " + .url + "  草稿=" + (.isDraft|tostring) + "  附件: " + (.assets[].name)'
