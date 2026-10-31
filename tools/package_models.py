#!/usr/bin/env python3
"""把转好的 Core ML 模型打成发布包, 并生成 sha256 清单。不上传, 发布由人来做。

用法: python3 tools/package_models.py --models <coreml 目录> --version v1 --out dist/
产物: dist/DocOCR-models-v1.zip, dist/DocOCR-models-v1.json(版本、文件名、大小、sha256、逐模型 sha256)。
把 json 里的 sha256/size 写进 mac/Sources/OCREngines/ModelStore.swift 的 ModelRelease。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def sha(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", type=Path, required=True)
    ap.add_argument("--version", default="v1")
    ap.add_argument("--out", type=Path, default=Path("dist"))
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    name = f"DocOCR-models-{a.version}"
    keep = sorted(p for p in a.models.iterdir() if p.suffix == ".mlpackage") + [a.models / "keys.txt", a.models / "manifest.json"]
    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / "models"
        root.mkdir()
        for p in keep:
            (shutil.copytree if p.is_dir() else shutil.copy2)(p, root / p.name)
        z = a.out / f"{name}.zip"
        z.unlink(missing_ok=True)
        subprocess.run(["ditto", "-c", "-k", "--noqtn", str(root), str(z)], check=True)
    manifest = json.loads((a.models / "manifest.json").read_text())
    info = {"version": a.version, "file": z.name, "size": z.stat().st_size, "sha256": sha(z),
            "onnx_sha256": manifest.get("onnx_sha256"),
            "models": {k: v.get("sha256") for k, v in manifest["models"].items() if (a.models / k).exists()}}
    (a.out / f"{name}.json").write_text(json.dumps(info, indent=1) + "\n", "utf-8")
    print(json.dumps({k: info[k] for k in ("file", "size", "sha256")}))
    print(f"模型 {len(info['models'])} 个; 许可: PP-OCR 模型 Apache-2.0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
