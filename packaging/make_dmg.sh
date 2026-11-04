#!/usr/bin/env bash
# 把 dist/DocOCR.app 做成可拖拽安装的 DMG（内含「应用程序」快捷方式）。
#   packaging/make_dmg.sh <版本号>     产物是 dist/DocOCR-<版本号>-macOS-arm64.dmg
# 先跑 packaging/build_app.sh --keep-app 生成 .app。本地和 CI（.github/workflows/release.yml）共用。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: packaging/make_dmg.sh <版本号>}"
APP=dist/DocOCR.app
DMG="dist/DocOCR-$VERSION-macOS-arm64.dmg"
[ -d "$APP" ] || { echo "✗ 没有 $APP（先跑 packaging/build_app.sh --keep-app）"; exit 1; }
codesign --verify --strict "$APP"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# ditto 保留 .app 内的符号链接和扩展属性；cp -R 在某些情况下会破坏签名
ditto "$APP" "$STAGE/DocOCR.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "DocOCR $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "✓ $DMG  $(du -h "$DMG" | cut -f1)"
echo "  sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
