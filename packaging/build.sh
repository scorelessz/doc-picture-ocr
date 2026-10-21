#!/usr/bin/env bash
#
#  一条命令从干净状态重建自依赖的 DocPictureOCR.app。
#
#      packaging/build.sh                     # 默认产出 dist/DocPictureOCR.app
#      packaging/build.sh --dist /somewhere   # 换个产出目录
#      packaging/build.sh --verify            # 建完顺手跑自依赖验证（env -i + --selftest）
#      packaging/build.sh --clean             # 只清理 build/ dist/，不构建
#      packaging/build.sh --version 1.2.0     # 写进 Info.plist 的版本号
#
#  幂等：重复跑同样的命令得到同样的结果（每次先清掉 build/ 和目标 .app）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/.venv/bin/python"
SPEC="$ROOT/packaging/OCR.spec"
APP_NAME="DocPictureOCR.app"

DIST="$ROOT/dist"
WORK="$ROOT/build"
VERSION="1.0.0"
DO_VERIFY=0
CLEAN_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dist)    DIST="$2"; shift 2 ;;
    --work)    WORK="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --verify)  DO_VERIFY=1; shift ;;
    --clean)   CLEAN_ONLY=1; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^#//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

APP="$DIST/$APP_NAME"
step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ──────────────────────────────────────────────────────────── 0. 清理
step "清理旧产物"
rm -rf "$WORK" "$APP" "$DIST/${APP_NAME%.app}"
ok "已清 $WORK 和 $APP"
if [ "$CLEAN_ONLY" = 1 ]; then exit 0; fi

# ──────────────────────────────────────────────────────────── 1. 环境自检
step "环境自检"
[ -x "$PY" ] || die "找不到 $PY —— 这台机器上的 .venv 还没建"
"$PY" -c 'import PyInstaller' 2>/dev/null || die "venv 里没有 PyInstaller"
"$PY" -c 'import tkinter' 2>/dev/null || die "venv 里的 python 没有 tkinter（brew install python-tk@3.13）"
[ -f "$ROOT/bin/vision-ocr" ] || die "缺 bin/vision-ocr：swiftc -O src/vision_ocr.swift -o bin/vision-ocr"
[ -f "$ROOT/src/run_books.py" ] || die "缺 src/run_books.py"
ok "python  $("$PY" -c 'import sys;print(sys.version.split()[0])')  @ $PY"
ok "PyInstaller $("$PY" -c 'import PyInstaller;print(PyInstaller.__version__)')"
ok "Tcl/Tk  $("$PY" -c 'import tkinter;print(tkinter.TkVersion)')"
ok "目标    $APP   版本 $VERSION"

# ──────────────────────────────────────────────────────────── 2. 图标
step "应用图标"
if [ -f "$ROOT/packaging/AppIcon.icns" ]; then
  ok "已有 packaging/AppIcon.icns"
else
  "$PY" "$ROOT/packaging/make_icon.py" && ok "已生成"
fi

# ──────────────────────────────────────────────────────────── 3. 打包
step "PyInstaller（onedir，几分钟）"
cd "$ROOT"
OCR_APP_VERSION="$VERSION" "$PY" -m PyInstaller \
  --noconfirm --clean --log-level=WARN \
  --distpath "$DIST" --workpath "$WORK" \
  "$SPEC"
[ -d "$APP" ] || die "PyInstaller 没有产出 $APP"
ok "已产出 $APP"

# ──────────────────────────────────────────────────────────── 4. macOS 收尾
step "macOS 收尾（可执行位 / 签名 / quarantine）"

RES="$APP/Contents/Resources"
VIS=""
for c in "$RES/bin/vision-ocr" "$APP/Contents/Frameworks/bin/vision-ocr"; do
  [ -f "$c" ] && VIS="$c" && break
done
[ -n "$VIS" ] || die "包里找不到 bin/vision-ocr —— spec 的 datas 没生效"
chmod 755 "$VIS"
ok "vision-ocr 可执行位已置 ($(cd "$(dirname "$VIS")" && pwd | sed "s|$APP/||")/vision-ocr)"

#  内层 Mach-O 先签，再签整包。没有这一步，某些 macOS 版本会在启动时
#  直接 SIGKILL（"code signature invalid"）。ad-hoc 签名无需任何证书。
codesign --force --sign - --timestamp=none "$VIS" 2>/dev/null \
  && ok "vision-ocr 已 ad-hoc 签名" || echo "  ! vision-ocr 签名失败（非致命）"

codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null \
  && ok "整包已 ad-hoc 签名" || echo "  ! 整包签名失败（非致命，但首次启动可能被拦）"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /' || true

#  本机构建的东西本来就没有 quarantine，但从网盘/压缩包拿过来的会有。
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
ok "已清 com.apple.quarantine"

# ──────────────────────────────────────────────────────────── 5. 体积
step "体积"
du -sh "$APP" | awk '{printf "  总计 %s\n", $1}'
du -sh "$APP/Contents/Frameworks"/* "$APP/Contents/Resources"/* 2>/dev/null \
  | sort -rh | head -12 | sed 's|'"$APP"'/Contents/|  |'

# ──────────────────────────────────────────────────────────── 6. 验证
if [ "$DO_VERIFY" = 1 ]; then
  step "自依赖验证（项目外路径 + env -i 清空环境）"
  TMP="$(mktemp -d /tmp/ocr-standalone.XXXXXX)"
  trap 'rm -rf "$TMP"' EXIT
  cp -R "$APP" "$TMP/"
  "$PY" "$ROOT/packaging/make_probe_pdf.py" "$TMP/probe.pdf" | sed 's/^/  探针 /'
  BIN="$TMP/$APP_NAME/Contents/MacOS/OCR"
  #  env -i：不给 PATH / PYTHONPATH / PYTHONHOME / VIRTUAL_ENV。
  #  只留 HOME（设置文件要写 ~/Library）和 TMPDIR。
  env -i HOME="$HOME" TMPDIR=/tmp \
      "$BIN" --selftest "$TMP/probe.pdf" --outdir "$TMP/out" \
    | sed 's/^/  /' \
    || die "空环境下的 --selftest 失败：这个 .app 不是自依赖的"
  [ -s "$TMP/out/probe.md" ] || die "没产出 probe.md"
  [ -s "$TMP/out/probe.searchable.pdf" ] || die "没产出 probe.searchable.pdf"
  ok "空环境、项目外路径，五步全通"
fi

step "完成"
echo "  打开：  open \"$APP\""
echo "  命令行：\"$APP/Contents/MacOS/OCR\" --selftest 某.pdf"
