# 被冒烟和安装脚本 source。用户的 App 在跑就停下，不杀它，也不替换它。
if pids=$(pgrep -x DocOCR; pgrep -x DocOCRApp); [ -n "$pids" ]; then
  echo "检测到 DocOCR 正在运行（PID: $(echo $pids)）。请先退出 App 再运行这个脚本。"
  exit 3
fi
