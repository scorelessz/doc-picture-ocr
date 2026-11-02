#!/usr/bin/env bash
# 组装 DocOCR.app：swift build → 拼包 → 打入 Core ML 模型 → ad-hoc 签名 → ditto 压缩。
#   packaging/build_app.sh               产物是 dist/DocOCR-<版本>.zip
#   packaging/build_app.sh --skip-build  用现成的 .build/release
#   packaging/build_app.sh --with-models 把 Core ML 模型打进包里，自用。默认不打包，使用者在 App 里下载或从文件导入
#   packaging/build_app.sh --keep-app    保留 dist/DocOCR.app（默认删掉：系统会把它当成第二个 App 索引）
# 没有开发者账号，只做本机签名，不做公证。PaddleOCR-VL 不打包，按需下载。
set -euo pipefail
cd "$(dirname "$0")/.."

SKIP=0; KEEP=0; WITH=0
for a in "$@"; do
  case "$a" in
    --skip-build) SKIP=1 ;;
    --keep-app) KEEP=1 ;;
    --with-models) WITH=1 ;;
    *) echo "未知参数: $a"; exit 2 ;;
  esac
done
MODELS="${DOCOCR_MODELS:-$HOME/Library/Application Support/DocOCR/models}"
if [ "$WITH" = 1 ]; then
  [ -f "$MODELS/keys.txt" ] || { echo "✗ 没有模型: $MODELS（先跑 ocr-cli models fetch）"; exit 1; }
fi
[ "$SKIP" = 1 ] || swift build -c release --product DocOCRApp

# 版本号：最近的 tag 去掉 v；构建号是提交数；完整 commit 记进 Info.plist
TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.0.0)
VERSION=${DOCOCR_VERSION:-${TAG#v}}
BUILD=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse --short=12 HEAD)
git diff --quiet HEAD -- mac Package.swift packaging || COMMIT="$COMMIT-dirty"

APP=dist/DocOCR.app; C="$APP/Contents"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources"
cp .build/release/DocOCRApp "$C/MacOS/DocOCR"
cp packaging/AppIcon.icns "$C/Resources/AppIcon.icns"
# mlx 在主 bundle 的 Resources 下找这个 bundle（Metal 着色器）
cp -R .build/release/mlx-swift_Cmlx.bundle "$C/Resources/"
# 只放预编译的 .mlmodelc：包内只读，不能现场编译
if [ "$WITH" = 1 ]; then
  mkdir -p "$C/Resources/models"
  cp "$MODELS/keys.txt" "$MODELS/manifest.json" "$C/Resources/models/"
  cp -R "$MODELS"/*.mlmodelc "$C/Resources/models/"
fi
cp docs/THIRD_PARTY_LICENSES.md "$C/Resources/"

cat > "$C/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.dococr.app</string>
  <key>CFBundleName</key><string>DocOCR</string>
  <key>CFBundleDisplayName</key><string>文档图片 OCR</string>
  <key>CFBundleExecutable</key><string>DocOCR</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>DocOCRGitCommit</key><string>$COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
</dict></plist>
P

# 由内到外签：先内嵌 bundle，再 App 本身
codesign --force -s - "$C/Resources/mlx-swift_Cmlx.bundle"
codesign --force -s - "$APP"
codesign --verify --strict --verbose=2 "$APP"

ZIP="dist/DocOCR-$VERSION-$BUILD.zip"
rm -f dist/DocOCR-*.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "✓ $APP  $(du -sh "$APP" | cut -f1)"
echo "✓ $ZIP  $(du -sh "$ZIP" | cut -f1)"
[ "$KEEP" = 1 ] || rm -rf "$APP"
