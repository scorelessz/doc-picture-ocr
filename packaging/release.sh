#!/usr/bin/env bash
# 发版：构建 → ad-hoc 签名 → 压缩 → 传到 GitHub Releases。
#
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

APP="$ROOT/dist/DocPictureOCR.app"
SKIP_BUILD=0; DRAFT=""; NOTES_FILE=""; VERSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --draft)      DRAFT="--draft"; shift ;;
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    -h|--help)    sed -n '2,16p' "$0"; exit 0 ;;
    -*)           echo "未知参数: $1"; exit 2 ;;
    *)            VERSION="$1"; shift ;;
  esac
done
[ -n "$VERSION" ] || { echo "用法: packaging/release.sh <版本号> [--skip-build] [--draft]"; exit 2; }
TAG="v$VERSION"

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
  packaging/build.sh --version "$VERSION"
fi
codesign --verify --deep "$APP" 2>&1 | sed 's/^/  /' || { echo "✗ 签名校验不过"; exit 1; }

# ── 压缩：必须用 ditto ───────────────────────────────────────────────
#  zip -r 会破坏 .app 里 Framework 的符号链接, 解压出来的包打不开。
#  ditto -c -k --sequesterRsrc --keepParent 是 Apple 自己推荐的做法。
say "压缩"
ZIP="$ROOT/dist/DocPictureOCR-$VERSION-macOS-arm64.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIZE=$(du -h "$ZIP" | cut -f1)
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "  $ZIP  $SIZE"
echo "  sha256 $SHA"

# ── 发布说明 ────────────────────────────────────────────────────────
if [ -n "$NOTES_FILE" ]; then
  NOTES=$(cat "$NOTES_FILE")
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

# ── 发布 ────────────────────────────────────────────────────────────
say "发布 $TAG"
gh release create "$TAG" "$ZIP" \
  --title "DocPictureOCR $TAG" \
  --notes "$NOTES" \
  $DRAFT
echo
gh release view "$TAG" --json url,isDraft,assets \
  -q '"✓ " + .url + "  草稿=" + (.isDraft|tostring) + "  附件: " + (.assets[].name)'
