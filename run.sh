#!/usr/bin/env bash
# 一键流水线: PDF -> 双引擎 OCR -> 交叉验证 -> 术语表/异常检测
#
# 用法:  ./run.sh <你的.pdf>
#
# 产物(全部在 work/ 下, 以 PDF 文件名为前缀):
#   <名>/pages/        抽出的页面原图(无重编码)
#   <名>.vision.json   Vision 引擎结果(坐标+文本+置信度)
#   <名>.rapidocr.json RapidOCR/PP-OCRv6 结果
#   <名>.crosscheck.json  可疑清单(两引擎分歧处)
# 最终 Markdown 输出在 output/<名>.md
set -euo pipefail
cd "$(dirname "$0")"

PDF="${1:-}"
if [[ -z "$PDF" ]]; then
    echo "用法: ./run.sh <pdf文件>" >&2
    exit 2
fi
if [[ ! -f "$PDF" ]]; then
    echo "文件不存在: $PDF" >&2
    exit 1
fi

PY=.venv/bin/python
STEM="$(basename "${PDF%.*}")"

echo "══ [1/5] Vision 引擎 (macOS 原生, 端上推理) ══"
$PY src/run_vision.py "$PDF"

echo
echo "══ [2/5] RapidOCR / PP-OCRv6 (ONNX Runtime, 本地) ══"
$PY src/run_rapidocr.py "$PDF"

echo
echo "══ [3/5] 交叉验证 ══"
$PY src/crosscheck.py "work/$STEM.vision.json" "work/$STEM.rapidocr.json"

echo
echo "══ [4/5] 术语表候选 + 语言学异常 ══"
$PY src/postcheck.py "work/$STEM.crosscheck.json"

echo
echo "══ [5/5] 输出 Markdown ══"
$PY src/to_markdown.py "work/$STEM.rapidocr.json"

echo
echo "完成。产物:"
echo "  可疑清单  work/$STEM.crosscheck.json"
echo "  Markdown  output/$STEM.md"
echo "下一步: 把上面「术语表候选」和「高频词组」里认出的误读，"
echo "        按 '正确词 <- 错误变体' 写进 config/glossary.txt，然后:"
echo "        $PY src/postcheck.py work/$STEM.crosscheck.json --apply"
