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
| `mineru25pro-mlx8` | MinerU2.5-Pro-2605-1.2B（MLX 8bit 社区版，或自己 `mlx_vlm convert`） | `mlx_vlm.server` | `mineru` | 整页走「文本识别」提示；版面两阶段放 Phase 5。核对模型卡里的任务提示词 |
| `ovisocr2-*` | OvisOCR2（`ATH-MaaS/OvisOCR2`） | 先试 mlx-vlm 转换，不行试 llama.cpp GGUF（Qwen3.5 结构），都不行用 transformers + MPS | `ovis` | 提示词以模型卡为准 |

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

## 5. Claude 多模态抽查（用户 2026-10-31 明确要求）

目的：PDF 原生文字层不一定是对的（第 8、9 页上多个引擎错得一模一样），需要一个独立的「看图读字」真值。
样本书已获用户授权可以离开本机（2026-10-31），抽查页图片会发给 Anthropic（由 Mac 上的 Claude 会话看图）。
转写原文留在 `work/bench/spot/`（仓库卫生），汇报里可以引用具体错例；仓库里只提交数字。

页集：`3 8 9 11 12 50 120 185 236 300`（正文/书前页）+ `10 20 62 98 160 324`（白页）。

```bash
.venv/bin/python bench/spot_prep.py "$PDF" 3 8 9 11 12 50 120 185 236 300 10 20 62 98 160 324
# 各模型 page / line 两种模式各重跑一遍, 加 --save-text 留原文(只在本机)
.venv/bin/python bench/p1_vlm.py "$PDF" ... --pages 3,8,9,11,12,50,120,185,236,300,10,20,62,98,160,324 --save-text
```

Claude 看图转写的规则：
1. **先转写、后看文字层**：转写时不打开 `pNNNN.native.json`，避免被锚定。
2. 逐张看条带图 `pNNNN-sKK.png`，按图上原样逐字转写（繁简、标点、全半角都照印刷），不纠错、不补全；
   看不清就把条带再裁小放大看，不要猜。整页转写写进 `work/bench/spot/claude/pNNNN.txt`。
3. 白页看整页图 `pNNNN.png`：图上没有正文就写空文件。
4. 转写完再与 `pNNNN.native.json` 逐行比；每处不一致回到图上裁决，计数写进
   `work/bench/spot/adjudication.json`：`{"页": {"diffs": n, "native": 文字层对, "claude": 转写对, "neither": 都不对, "unclear": 看不清}}`。

```bash
.venv/bin/python bench/spot_score.py "$PDF"     # → bench/results/p1-spotcheck.json
```

## 6. 线上模型调用策略（用户 2026-10-31 决定）

| 平台 | 用途 | 原则 |
|---|---|---|
| 阿里云百炼（通义千问） | 首选：大视觉模型对照、看图转写与裁决等程序性比对 | 预算充足，可用任意靠谱模型 |
| 硅基流动 | 首选：托管的开源 OCR / 视觉模型，与本地同款模型对照 | 同上 |
| OpenRouter | **只**调用前两家没有的高价高性能模型 | 贵，非必要不调用；每次调用前说明理由 |
| Anthropic API | 不使用 | — |

- 程序性比对（转写、逐条裁决、多模型对照）一律交给 Qwen，不用 Claude 看图，节省 Claude 额度。
- 线上调用需用户在 Mac 会话里本人确认；key 只由脚本从文件读取，不打印、不进命令行、不进提交。
