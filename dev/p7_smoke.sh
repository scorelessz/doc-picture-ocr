#!/bin/zsh
# App 冒烟：两本书各 5 页走 QueueModel 全流程，再用一本整书测中途取消。结果只有数字，写 bench/results/p7-smoke.json。
#   ./dev/p7_smoke.sh "英文书.pdf" "中文书.pdf"
set -eu
cd "$(dirname "$0")/.."
[[ $# -eq 2 ]] || { echo "用法: $0 英文书.pdf 中文书.pdf"; exit 2; }
source dev/guard_instances.sh
swift build -c release 2>&1 | tail -1
W=work/p7/smoke; rm -rf $W; mkdir -p $W/out $W/cancel
.venv/bin/python - "$1" "$2" "$W" <<'P'
import sys, pymupdf
for src, name in zip(sys.argv[1:3], ("en5.pdf", "zh5.pdf")):
    d = pymupdf.open(src); o = pymupdf.open()
    o.insert_pdf(d, from_page=49, to_page=53)
    o.save(f"{sys.argv[3]}/{name}")
P
.build/release/DocOCRApp --smoke $PWD/$W/out $PWD/$W/en5.pdf $PWD/$W/zh5.pdf
.build/release/DocOCRApp --smoke $PWD/$W/cancel "$2" --cancel-after 15
python3 - "$W" <<'P'
import json, sys
w = sys.argv[1]
a, c = json.load(open(f"{w}/out/smoke.json")), json.load(open(f"{w}/cancel/smoke.json"))
out = {"phase": "p7", "name": "app-smoke", "books": a, "cancel": c}
for r in a + c:
    r["pdf"] = r["pdf"].rsplit(".", 1)[0][:8]
json.dump(out, open("bench/results/p7-smoke.json", "w"), ensure_ascii=False, indent=1)
ok = len(a) == 2 and all(r["status"] == "done" and r["pages"] == 5 and r["outputs"] == 3 and not r["degraded"] for r in a) and c[0]["status"] == "cancelled"
print(json.dumps(out, ensure_ascii=False)[:900]); print("通过" if ok else "失败"); sys.exit(0 if ok else 1)
P
