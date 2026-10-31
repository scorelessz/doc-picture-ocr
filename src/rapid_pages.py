#!/usr/bin/env python3
"""Swift 总流程的 RapidOCR 桥接(Phase 4 换 Core ML 后删除): 读 PNG 清单, 写逐页识别行。

用法: .venv/bin/python src/rapid_pages.py <manifest.json> <out.json>
  manifest: [{"page": 1, "png": "/abs/p0001.png"}, ...]
  out:      {"lines": {"1": [{"x","y","w","h","conf","text"}, ...]}, "failed": [页号...]}
单页失败不中断, 记进 failed, 由调用方判降级。先写 .part 再改名。
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from book_engines import _rapid_normalize, rapid_engine   # noqa: E402


def main() -> int:
    items = json.loads(Path(sys.argv[1]).read_text("utf-8"))
    out = Path(sys.argv[2])
    engine = rapid_engine(False)
    lines: dict[str, list] = {}
    failed: list[int] = []
    for n, it in enumerate(items, 1):
        try:
            lines[str(it["page"])] = _rapid_normalize(engine(it["png"]))
        except Exception as e:                            # noqa: BLE001
            failed.append(it["page"])
            lines[str(it["page"])] = []
            print(f"第{it['page']}页 RapidOCR 失败: {e}", file=sys.stderr)
        if n % 50 == 0:
            print(f"RapidOCR {n}/{len(items)}", file=sys.stderr, flush=True)
    part = out.with_name(out.name + ".part")
    part.write_text(json.dumps({"lines": lines, "failed": failed}, ensure_ascii=False), "utf-8")
    part.replace(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
