# 诊断日志结构

`ocr-cli` 所有子命令都支持（细则见 `REFACTOR_PLAN.md` §5.1）：

```
--log-level error|warn|info|debug|trace   默认不开；只给 --log-file 时为 info
--log-file 路径                            不给则写 stderr；已有文件时追加
--log-format json|text                    默认 json，每行一条
--log-text                                才写识别正文，默认不写
DOCOCR_LOG=debug                          等价于 --log-level，命令行优先
```

日志只落本地，不上传。stdout 不受影响，脚本解析 `vision` 的 TSV 等不会被打断。

新机器先跑 `ocr-cli doctor [--models-dir 目录] [--outdir 目录] [--out checks.json]`。它只检查环境，不处理书：
macOS 版本、磁盘、Vision、PDFKit、写权限、模型文件，以及 ANE / all / CPU 三种计算单元各跑一次样张。
`✓` 通过，`✗` 必需项失败（退出码 1），`△` 可选项失败（ANE、all 不可用时，CPU 还能跑）。

## 事件

每行都有 `t`（启动后秒数）、`level`、`event`。

| event | level | 字段 |
|---|---|---|
| `env` | info | `macos` `chip` `ram_gb` `cpus` `disk_free_gb` `commit` `vision_text_revision` `models`（文件名 → sha256 前 12 位）`argv` |
| `start` | info | `command` `log_text` |
| `compute_plan` | info | `model` `requested`（ane/all/cpu/gpu）`ops` `ane` `gpu` `cpu`（各设备的算子数） |
| `stage` | info | `name` `seconds` `peak_rss_mb` `peak_rss_children_mb`；`ppocr-coreml` 另有 `units` `load_seconds` `det` `post` `crop` `rec` `canvas_fallbacks` |
| `page` | debug | `page` `dpi` `width` `height` `dark` `gate` `vision_lines` `vision_seconds` `ppocr_lines` `ppocr_seconds` `fused_lines` `divergent` `only_vision` `only_ppocr` `dedup` `dedup_new_rule`；`--log-text` 时多 `lines` |
| `md` | info | `paragraphs` `headings` `chars` `vlm_break_overrides` `dropped`（理由 → 条数）`vertical_pages` `two_column_pages` |
| `md_dropped` | debug | `page` `reason`；`--log-text` 时多 `text` |
| `pdf` | info | `embedded` `skipped_native` `skipped_gate` `retrieval` `line_retrieval` `probe_found` `probe_checked` `size_in` `size_out` |
| `vlm_page` | debug | `page` `seconds` `raw_chars` `kept_chars` `truncated` `loop_cut` `flips` `orphans` |
| `vlm_loaded` | info | `model` `seconds` `runtime` |
| `vlm` | info | `pages` `called` `skipped_no_ink` `skipped_no_divergence` `flips` `orphans` |
| `vl_fetched` | info | `dir` `repo` `revision` |
| `vl_fetch_rejected` | error | `file` `want` `got` |
| `network_switch` | info | `allowed` |
| `gate_request` | info | `host` `items` `bytes` `requests` `digest` |
| `gate_decision` | info | `decision` `scope` `ticket` |
| `gate_revoked` | warn | `reason` `ticket` |
| `provider_request` | debug | `host` `provider` `bytes` `attempt` |
| `provider_response` | debug | `host` `status` `bytes` `seconds` |
| `provider_refused` | warn | `reason` `host` `provider` 或 `item` |
| `redirect_blocked` | warn | `from` `to` |
| `upload_mismatch` | error | `detail` |
| `app_start` | info | `pid` `path` `version` `commit` |
| `app_exit` | info | `pid`（正常退出） |
| `app_signal` | warn | `signal`（SIGTERM、SIGHUP） |
| `app_exception` | error | `name` `reason` |
| `provider_test_start` / `provider_test_end` | info | `provider` `model` / `provider` `result` |
| `provider_models` | info / warn | `provider` `ok` `count` 或 `reason` |
| `probe_rung` | debug | `edge` `want` `digits` `reply_chars`（只有合成图的随机码） |
| `probe_result` | info | `host` `model` `supports_image` `max_long_edge` `response_format` |
| `orientation` | debug | `rotation` `conf0` `best` |
| `tiled` | debug | `tiles` `width` `height` |
| `models_fetched` | info | `dir` `sha256` |
| `warning` | warn | `message`，有页号时带 `page` |
| `pdf_warning` `degraded` | warn | `message` |
| `engine_failed` | error | `page` `engine` `stage` `error` |
| `refused` `failed` | error | `command` `error`，`failed` 另有 `type` |
| `doctor` | info | `check` `ok` `detail` |
| `progress` | debug | `message` |
| `end` | info | `command` `seconds` `peak_rss_mb` `peak_rss_children_mb` |

`page` 另有 `page_rotation`。`gate` 取值：`ocr`、`native_text`（有文字层，未做 OCR）、`no_ink_native_text`（无墨迹，改用文字层）、`no_ink_blank`（无墨迹，按白页处理）。

`peak_rss_children_mb` 在 `--paddle coreml` 下是 0，因为不再有 Python 子进程。

上传记录写在 `<stem>.uploads.jsonl`，每次状态变化追加一行，先写后发；同一 `seq` 以最后一行为准。

## 隐私

没有 `--log-text` 时不写任何识别文本。`argv` 和 `warning` 里会有文件路径，所以书名会出现在日志里，发给别人前看一下。
`--log-text` 的日志含全书正文，不要提交。
