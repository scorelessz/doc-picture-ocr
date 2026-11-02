# bench

历史基准：`bench/results/` 的数字和生成它们的脚本。很多脚本依赖已删除的 `src/` 和 `.venv`，现在不能直接运行。

恢复方法：

```bash
git checkout python-final -- src requirements.txt
python3.13 -m venv .venv && .venv/bin/pip install -r requirements.txt rapidfuzz
```
