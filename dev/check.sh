#!/bin/bash
# 在你的 Mac 上跑某个阶段的检查: 装依赖 -> 构建 -> 测试/基准, 结果(只有数字)写进 bench/。
#
#   ./dev/check.sh p0 "/path/to/书.pdf" [--pages 1-20]
set -euo pipefail
cd "$(dirname "$0")/.."

stage="${1:-}"; shift || true
[ "$(uname -s)" = Darwin ] || { echo "只能在 macOS 上跑"; exit 2; }

need_venv() {
  if [ ! -x .venv/bin/python ]; then
    py=""
    for c in python3.13 /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13; do
      command -v "$c" >/dev/null 2>&1 && { py="$c"; break; }
    done
    if [ -z "$py" ] && command -v uv >/dev/null 2>&1; then
      uv venv --python 3.13 .venv
    elif [ -n "$py" ]; then
      "$py" -m venv .venv
    else
      echo "找不到 Python 3.13: brew install python@3.13 (或装 uv)"; exit 2
    fi
  fi
  .venv/bin/python -m pip install -q --upgrade pip
  .venv/bin/python -m pip install -q -r requirements.txt rapidfuzz
}

need_vision() {
  command -v swiftc >/dev/null || { echo "缺 swiftc: xcode-select --install"; exit 2; }
  if [ ! -x bin/vision-ocr ] || [ src/vision_ocr.swift -nt bin/vision-ocr ]; then
    mkdir -p bin && swiftc -O src/vision_ocr.swift -o bin/vision-ocr
  fi
}

case "$stage" in
  p0)
    [ $# -ge 1 ] || { echo "用法: ./dev/check.sh p0 <pdf> [--pages A-B]"; exit 2; }
    need_venv
    need_vision
    caffeinate -i .venv/bin/python bench/p0_baseline.py "$@"
    ;;
  *)
    echo "用法: ./dev/check.sh p0 <pdf> [--pages A-B]"; exit 2 ;;
esac
