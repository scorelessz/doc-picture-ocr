#!/bin/bash
# 一键 OCR —— 在 Finder 里**双击**这个文件即可。
#
#   input/ 下的所有 PDF  ->  output/<名>.md          段落化正文
#                            output/<名>.searchable.pdf  原图 + 隐形文字层(可搜索可复制)
#                            work/<名>.report.md     质量报告
#
# 已经处理过的文件会自动跳过(产物还在就不重做)。全程本地运行, 不联网。
# 想在终端里跑、或者要调参数, 用 ./books.sh --help。

cd "$(dirname "$0")" || { echo "进不去脚本所在目录"; exit 1; }
ROOT="$(pwd)"
IN="${1:-input}"                 # 可选: 拖一个文件夹进来当输入
OUT="output"

# ── 让输出好看一点 ──────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'; G=$'\033[32m'; Y=$'\033[33m'
else B=""; D=""; R=""; G=""; Y=""; fi
line() { printf '%s\n' "────────────────────────────────────────────────────"; }
pause() {                        # 双击打开的窗口不要一闪而过
  if [ -t 0 ]; then printf '\n%s' "${D}按任意键关闭这个窗口…${R}"; read -r -n 1 -s; echo; fi
}

echo
echo "${B}中文扫描件 OCR · 一键处理${R}"
line
echo "项目:  $ROOT"
echo "输入:  $IN/"
echo "输出:  $OUT/   (Markdown + 可搜索 PDF)"
line

# ── 环境自检 ───────────────────────────────────────────────
fail() { echo; echo "${Y}✗ $1${R}"; pause; exit 1; }
[ -x ".venv/bin/python" ] || fail "找不到 .venv/bin/python —— 虚拟环境不在了, 见 BOOKS.md「环境增项」"
[ -x "bin/vision-ocr" ]   || fail "找不到 bin/vision-ocr —— 重新编译: swiftc -O src/vision_ocr.swift -o bin/vision-ocr"
[ -f "books.sh" ]         || fail "找不到 books.sh"
mkdir -p "$IN" "$OUT" work

# ── 清点待办 ───────────────────────────────────────────────
#  用 NUL 分隔读文件名, 中文/空格/括号都不会出问题
todo=(); done_=()
while IFS= read -r -d '' f; do
  stem="$(basename "$f")"; stem="${stem%.*}"
  if [ -f "$OUT/$stem.md" ] && [ -f "$OUT/$stem.searchable.pdf" ]; then
    done_+=("$stem")
  else
    todo+=("$stem")
  fi
done < <(find "$IN" -maxdepth 1 -type f -iname '*.pdf' -not -name '._*' -print0 2>/dev/null | sort -z)

if [ ${#todo[@]} -eq 0 ] && [ ${#done_[@]} -eq 0 ]; then
  echo "${Y}input/ 里还没有 PDF。${R}"
  echo "把要识别的扫描件放进去, 再双击一次这个脚本就行。"
  command -v open >/dev/null && open "$IN"      # 顺手把文件夹打开
  pause; exit 0
fi

[ ${#done_[@]} -gt 0 ] && { echo "${D}已处理过, 这次跳过 (${#done_[@]}):${R}";
                            for s in "${done_[@]}"; do echo "${D}  · $s${R}"; done; }
if [ ${#todo[@]} -eq 0 ]; then
  echo
  echo "${G}✓ input/ 里的文件都已经处理完了, 没有新活。${R}"
  echo "${D}想重做某一份: 先删掉它在 output/ 下的两个产物, 或在终端跑 ./books.sh --force${R}"
  command -v open >/dev/null && open "$OUT"
  pause; exit 0
fi

echo "${B}本次要处理 ${#todo[@]} 份:${R}"
for s in "${todo[@]}"; do echo "  · $s"; done
echo
echo "${D}书籍扫描件约 1.4 秒/页 —— 一本 400 页的书大概 9 分钟。中途可以按 Control-C 停。${R}"
line

# ── 防止两个窗口同时开跑(会抢 work/ 下的中间文件) ──────────
LOCK="work/.books.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  fail "已经有一次处理在跑了(锁: $LOCK)。等它跑完; 若确认没有在跑, 删掉这个目录再试。"
fi
cleanup() { rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT INT TERM

# ── 开跑。caffeinate 防止跑到一半 Mac 睡过去 ───────────────
start=$(date +%s)
#  只传 --input: --outdir / --work-dir 一律走默认(output/ 与 work/)。
#  传了 --outdir 的话中间产物和质量报告会跟着挪到 <outdir>/work/, 和下面打印的路径对不上。
if command -v caffeinate >/dev/null; then
  caffeinate -i ./books.sh --input "$IN"       # caffeinate: 跑的时候别让 Mac 睡过去
else
  ./books.sh --input "$IN"
fi
code=$?
secs=$(( $(date +%s) - start ))
if [ $secs -lt 60 ]; then took="${secs} 秒"
else took="$((secs / 60)) 分 $((secs % 60)) 秒"; fi

line
case $code in
  0) echo "${G}✓ 全部完成${R}（用时 ${took}）" ;;
  3) echo "${Y}⚠ 完成, 但有降级项${R}（用时 ${took}）—— 质量报告第一屏写明了原因, 产物别全信" ;;
  *) echo "${Y}✗ 有文件没能处理完(退出码 $code)${R} —— 往上翻, 失败原因就在日志里" ;;
esac
echo
echo "产物:      $ROOT/$OUT/"
echo "质量报告:  $ROOT/work/<名>.report.md"
echo "${D}没有人工校对环节, 报告是唯一的质量抓手 —— 至少扫一眼「优先复核的页」。${R}"
[ $code -eq 0 ] && command -v open >/dev/null && open "$OUT"
pause
exit $code
