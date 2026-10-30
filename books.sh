#!/usr/bin/env bash
# 书籍线一键入口: input/ 下所有扫描件 PDF -> 可搜索 PDF + Markdown
#
# 用法:  ./books.sh                      处理 input/ 下全部 PDF
#        ./books.sh --force              重做(覆盖已有产物)
#        ./books.sh --resume             续跑(复用已有中间产物, 不覆盖)
#        ./books.sh --input DIR --outdir DIR --dpi 400 --jobs 4
#        ./books.sh --help               全部参数
#
# 产物(以 PDF 文件名为前缀):
#   output/<名>.md               段落化正文 Markdown
#   output/<名>.searchable.pdf   原图不动 + 隐形文字层, 可搜索可复制
#   work/<名>.report.md          质量报告(没有人工校对环节, 这是唯一的质量抓手)
#   work/<名>.{vision,rapidocr,fused}.json   逐行识别与融合数据
#
# 全程本地推理, 不联网。已有产物默认跳过, 不覆盖任何已存在的文件。

set -euo pipefail
cd "$(dirname "$0")"

PY=.venv/bin/python
exec "$PY" src/run_books.py "$@"
