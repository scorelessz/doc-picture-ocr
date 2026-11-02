#!/bin/bash
# 单测和工程检查:  ./dev/check.sh [p6|p7]，不带参数跑全部
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "只能在 macOS 上跑"; exit 2; }
# 发网络的代码只能在 Transport.swift
if grep -rlw "URLSession" mac/Sources | grep -v "OCRProviders/Transport.swift"; then
  echo "上面的文件直接用了 URLSession"; exit 1
fi
case "${1:-}" in
  p6) swift test --filter OCRProvidersTests ;;
  p7) swift test --filter DocOCRAppCoreTests ;;
  "") swift test ;;
  *) echo "用法: ./dev/check.sh [p6|p7]"; exit 2 ;;
esac
