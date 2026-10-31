# Phase 1 实测手册（在 Mac 上跑）

目的：用数据决定默认引擎组合与运行时（`REFACTOR_PLAN.md` §6 Phase 1）。
**只记数字**：识别文本不落盘、不打印、不提交。结果写 `bench/results/p1-*.json`。

前提：已跑过 P0（`work/bench/` 下有 `<名>.{vision,rapidocr,fused}.json`）。
机器：M4 / 16 GB → VLM 只测 ~1B 档；MiniCPM-V 4.7 的 35B-A3B 不测。

## 页集

默认 `3,8-12,20,62,98,160,324`：
- 10 / 20 / 62 / 98 / 160 / 324：P0 两个 CTC 引擎整页 0 行的页（看 VLM 能否读出）
- 3 / 8 / 9：P0 错得最多的书前页
- 11 / 12：正常正文页（对照）

确认可用后再扩到全书抽样（如 `1-328` 每 8 页取 1 页）。

## 0. 对照组（不需要模型）

```bash
.venv/bin/python bench/p1_ctc.py "$PDF"
```

## 1. 运行时

```bash
brew install llama.cpp          # 提供 llama-server（Metal）
.venv/bin/pip install "huggingface_hub[cli]" mlx-vlm   # mlx-vlm 只在测 MLX 时需要
```

所有模型都以 OpenAI 兼容服务启动，测试脚本只认 `--base-url`。启动后记下服务进程 PID 传给 `--server-pid`，用来记内存峰值。

## 2. 模型矩阵

| 名称（--name） | 模型 | 运行时 | --prompt-id | 备注 |
|---|---|---|---|---|
| `xiaomi-q8-llamacpp` | Xiaomi-OCR-0 GGUF Q8_0 + mmproj | llama-server | `xiaomi` | 社区 GGUF：`xzl01/Xiaomi-OCR-0-GGUF` 的 release |
| `xiaomi-bf16-mps` | Xiaomi-OCR-0 原版 | transformers + MPS（自写极简 OpenAI 兼容封装或 vLLM 不可用时跳过） | `xiaomi` | 用来核对社区 GGUF 是否掉精度 |
| `minicpm47-1b-llamacpp` | MiniCPM-V 4.7 1B GGUF + mmproj | llama-server | `minicpm` | 在 HF 的 openbmb 组织下找官方 gguf |
| `paddlevl16-mlx` | PaddleOCR-VL-1.6 | `mlx_vlm.server` | `paddlevl` | PaddleOCR 官方 Apple Silicon 教程用的就是 mlx-vlm |

llama-server 启动模板：

```bash
llama-server -m <model.gguf> --mmproj <mmproj.gguf> -c 8192 -ngl 99 --host 127.0.0.1 --port 8080 &
echo $!   # → --server-pid
```

## 3. 每个模型跑两种喂法

```bash
.venv/bin/python bench/p1_vlm.py "$PDF" --name <名称> --base-url http://127.0.0.1:8080/v1 \
    --model <服务里的模型名> --prompt-id <id> --mode page --server-pid <PID>
.venv/bin/python bench/p1_vlm.py "$PDF" --name <名称> --base-url http://127.0.0.1:8080/v1 \
    --model <服务里的模型名> --prompt-id <id> --mode line --server-pid <PID>
```

line 模式请求数 ≈ 行数（每页约 40），先只跑 `--pages 11,12` 估时间，再决定要不要跑全页集。

## 4. 汇报

- 提交 `bench/results/p1-*.json` 并推送。
- 每个模型记：模型文件来源（HF repo + 文件名 + sha256 前 12 位）、量化、运行时版本、是否跑通。
- 跑不通的组合写清报错原文（不含书的内容），不要为跑通而改仓库代码。
