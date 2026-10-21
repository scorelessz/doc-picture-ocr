#!/bin/bash
# 启动图形界面（从源码跑，不用打包）—— 在 Finder 里**双击**这个文件。
#
# 和 一键OCR.command 的区别:
#   一键OCR.command   无界面, 双击就把 input/ 下的 PDF 全跑完
#   启动界面.command   开图形窗口, 可以挑文件、调参数、看进度、随时取消
#
# 依赖 .venv —— 这是**开发态**入口, 改完 app/ 下的代码双击就能看效果,
# 不需要重新打包。打包好的 DocPictureOCR.app 则是自依赖的, 不需要 .venv。
#
# 这个终端窗口是**日志窗口**: 界面的输出和报错都打在这里, 关掉它界面也会退出。

cd "$(dirname "$0")" || { echo "进不去脚本所在目录"; exit 1; }

if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'; Y=$'\033[33m'
else B=""; D=""; R=""; Y=""; fi
pause() { if [ -t 0 ]; then printf '\n%s' "${D}按任意键关闭…${R}"; read -r -n 1 -s; echo; fi; }
fail() { echo; echo "${Y}✗ $1${R}"; echo; [ -n "$2" ] && echo "  $2"; pause; exit 1; }

echo
echo "${B}中文扫描件 OCR · 图形界面${R}（开发态，从源码启动）"
echo "${D}项目 $(pwd)${R}"

# ── 环境自检：把「双击没反应」变成一句能照做的提示 ──────────────────
[ -x ".venv/bin/python" ] || fail \
  "没有 .venv —— 图形界面要从源码跑，必须有虚拟环境。" \
  "重建: python3.13 -m venv .venv && .venv/bin/pip install -r requirements.txt"

.venv/bin/python -c "import tkinter" 2>/dev/null || fail \
  "Python 装了但没有 Tk —— 图形界面起不来。" \
  "装上: brew install python-tk@3.13"

[ -d "app" ] || fail "找不到 app/ 目录（界面代码在这里）"
[ -x "bin/vision-ocr" ] || echo "${Y}⚠ bin/vision-ocr 不在或没有可执行位 —— 只剩 RapidOCR 单引擎${R}
  重编: swiftc -O src/vision_ocr.swift -o bin/vision-ocr"

echo "${D}日志打在这个窗口里；关掉窗口界面也会退出。${R}"
echo

# caffeinate: 跑长任务时别让 Mac 睡过去（和 一键OCR.command 一致）
if command -v caffeinate >/dev/null; then
  caffeinate -i .venv/bin/python -m app "$@"
else
  .venv/bin/python -m app "$@"
fi
code=$?

echo
if [ $code -eq 0 ]; then
  echo "${D}界面已退出。${R}"
else
  echo "${Y}界面异常退出（退出码 $code）${R} —— 上面的 traceback 就是原因。"
  pause
fi
exit $code
